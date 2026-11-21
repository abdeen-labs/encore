import EncoreCore
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS

/// A loaded text-to-speech model and the adapter that maps Encore jobs onto it.
protocol MLXSpeechEngine: AnyObject {
    var sampleRate: Int { get }
    func synthesize(_ job: SynthesisJob, reference: MaterializedArray?, parameters: ResolvedParameters) async throws -> MLXArray
}

/// A loaded speech-to-text model.
protocol MLXTranscriptionEngine: AnyObject {
    var sampleRate: Int { get }
    func transcribe(_ audio: MLXArray, job: TranscriptionJob, parameters: ResolvedParameters) throws -> Transcript
}

/// Resolves a repo id to the local directory a loader should read (see `MLXRepoStaging`).
typealias RepoDirectory = (String) throws -> URL

enum MLXEngines {
    /// What this backend has been verified to do, per engine key (`ModelManifest.engine`).
    /// Only list an engine here once real generations through `encore-cli mlx` came back intelligible.
    static let features: [String: EngineFeatures] = [
        "qwen3_tts": [.synthesis, .cloning, .voiceDesign],
        // Not "chatterbox" (Multilingual v3): the Swift port has no language tokens or v3 text handling, has no
        // built-in voice for it, and cloned English came back ~66% word errors. It belongs to the Python backend.
        "chatterbox_turbo": [.synthesis, .cloning],
        "voxcpm2": [.synthesis, .cloning, .voiceDesign],
        "omnivoice": [.synthesis, .cloning, .voiceDesign],
        "llama": [.synthesis],  // Orpheus
        "soprano": [.synthesis],
        "zonos3": [.synthesis, .cloning],
        // Segment timestamps only. Whisper word timings and Parakeet token timings aren't exposed by the Swift port.
        "whisper": [.transcription],
        "parakeet": [.transcription],
    ]

    static func loadSpeech(_ context: ModelLoadContext, directory: RepoDirectory) async throws -> MLXSpeechEngine {
        let repo = context.variant.repo
        switch context.manifest.engine {
        case "qwen3_tts":
            let dir = try directory(repo)
            let kind = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("config.json")))
                as? [String: Any])?["tts_model_type"] as? String
            return Qwen3Engine(try await Qwen3TTSModel.fromModelDirectory(dir), kind: kind ?? "base")
        case "chatterbox_turbo":
            // The loader fetches mlx-community/S3TokenizerV2 through mlx-audio's own cache path, which is staged.
            _ = try directory("mlx-community/S3TokenizerV2")
            return ChatterboxEngine(try await ChatterboxModel.fromModelDirectory(try directory(repo), hfToken: nil))
        case "voxcpm2":
            return VoxCPM2Engine(try await VoxCPM2Model.fromModelDirectory(try directory(repo), hfToken: nil))
        case "omnivoice":
            // OmniVoice only loads through mlx-audio's own cache path; the staged copy satisfies it offline.
            _ = try directory(repo)
            return OmniVoiceEngine(try await OmniVoiceModel.fromPretrained(repo, cache: .default))
        case "llama":
            // Orpheus. Its SNAC codec (mlx-community/snac_24khz) resolves through mlx-audio's cache path, staged.
            return GenericSpeechEngine(try await LlamaTTSModel.fromModelDirectory(try directory(repo), cache: .default))
        case "soprano":
            return GenericSpeechEngine(try await SopranoModel.fromModelDirectory(try directory(repo), repo: repo))
        case "zonos3":
            return Zonos3Engine(try await Zonos3Model.fromModelDirectory(try directory(repo)))
        default:
            throw EngineError.unsupported("The MLX Swift backend has no \(context.manifest.engine) engine.")
        }
    }

    static func loadTranscription(_ context: ModelLoadContext, directory: RepoDirectory) async throws -> MLXTranscriptionEngine {
        let dir = try directory(context.variant.repo)
        switch context.manifest.engine {
        case "whisper":
            // HF-format repos ship their tokenizer; older weight-only repos would fetch it from openai/whisper-*.
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path) else {
                throw EngineError.failed("\(context.variant.repo) has no tokenizer.json; use an HF-format (\"-asr-\") Whisper repo.")
            }
            return WhisperEngine(try await WhisperModel.fromDirectory(dir, cache: .default))
        case "parakeet":
            return ParakeetEngine(try await STT.loadModel(modelRepo: dir.path, modelType: "parakeet"))
        default:
            throw EngineError.unsupported("The MLX Swift backend has no \(context.manifest.engine) engine.")
        }
    }
}

// MARK: - Text to speech

final class Qwen3Engine: MLXSpeechEngine {
    let model: Qwen3TTSModel
    /// `base` (cloning), `custom_voice` (preset speakers + style) or `voice_design` (description).
    let kind: String
    init(_ model: Qwen3TTSModel, kind: String) { self.model = model; self.kind = kind }
    var sampleRate: Int { model.sampleRate }

    func synthesize(_ job: SynthesisJob, reference: MaterializedArray?, parameters: ResolvedParameters) async throws -> MLXArray {
        let instruct = job.instruct?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let voice: String?
        switch kind {
        case "custom_voice":
            // The Swift port takes "speaker, instruction" in `voice`.
            let speaker = job.voice?.preset ?? "vivian"
            voice = instruct.map { "\(speaker), \($0)" } ?? speaker
        case "voice_design":
            guard let instruct else { throw EngineError.failed("Describe the voice you want (voice design needs a description).") }
            voice = instruct
        default:
            voice = nil
        }
        let refText = reference == nil ? nil : job.voice?.referenceText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return try await model.generate(
            text: job.text, voice: voice, refAudio: reference, refText: refText,
            language: job.language ?? "auto",
            generationParameters: parameters.generateParameters(base: model.defaultGenerationParameters))
    }
}

final class ChatterboxEngine: MLXSpeechEngine {
    let model: ChatterboxModel
    init(_ model: ChatterboxModel) { self.model = model }
    var sampleRate: Int { model.sampleRate }

    func synthesize(_ job: SynthesisJob, reference: MaterializedArray?, parameters: ResolvedParameters) async throws -> MLXArray {
        // Regular Chatterbox reads these two from the model; Turbo ignores them.
        model.emotionAdvOverride = parameters.float("exaggeration")
        model.cfgWeightOverride = parameters.float("cfg_weight")
        var p = model.defaultGenerationParameters
        p.temperature = parameters.float("temperature") ?? 0.8
        p.topP = parameters.float("top_p") ?? p.topP
        return try await model.generate(text: job.text, voice: nil, refAudio: reference, refText: nil,
                                        language: job.language, generationParameters: p)
    }
}

final class VoxCPM2Engine: MLXSpeechEngine {
    let model: VoxCPM2Model
    init(_ model: VoxCPM2Model) { self.model = model }
    var sampleRate: Int { model.sampleRate }

    func synthesize(_ job: SynthesisJob, reference: MaterializedArray?, parameters: ResolvedParameters) async throws -> MLXArray {
        // Voice design is a parenthesized description in front of the text, as upstream does it.
        var text = job.text
        if let instruct = job.instruct?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            text = "(\(instruct))\(text)"
        }
        var p = model.defaultGenerationParameters
        p.maxTokens = parameters.int("max_tokens") ?? 2000
        return try await model.generate(text: text, voice: nil, refAudio: reference, refText: nil,
                                        language: job.language, generationParameters: p)
    }
}

final class OmniVoiceEngine: MLXSpeechEngine {
    let model: OmniVoiceModel
    init(_ model: OmniVoiceModel) { self.model = model }
    var sampleRate: Int { model.sampleRate }

    func synthesize(_ job: SynthesisJob, reference: MaterializedArray?, parameters: ResolvedParameters) async throws -> MLXArray {
        // Prose would be spoken or ignored: only the documented attribute list designs a voice.
        if let instruct = job.instruct, let problem = OmniVoiceAttributes.problem(with: instruct) { throw EngineError.unsupported(problem) }
        var p = OmniVoiceGenerateParameters()
        if let v = parameters.int("num_steps") { p.numStep = v }
        if let v = parameters.float("guidance_scale") { p.guidanceScale = v }
        if let v = parameters.float("t_shift") { p.tShift = v }
        if let v = parameters.float("class_temperature") { p.classTemperature = v }
        if let v = parameters.float("position_temperature") { p.positionTemperature = v }
        if let v = parameters.float("layer_penalty_factor") { p.layerPenaltyFactor = v }
        if let v = parameters.float("duration_s"), v > 0 { p.duration = v }
        p.seed = parameters.seed
        let refText = reference == nil ? nil : job.voice?.referenceText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return try await model.generate(
            text: job.text, voice: job.instruct?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            refAudio: reference, refText: refText, language: job.language, ovParameters: p)
    }
}

/// Models driven entirely through `SpeechGenerationModel` with a preset voice and the shared sampling knobs.
final class GenericSpeechEngine: MLXSpeechEngine {
    let model: SpeechGenerationModel
    init(_ model: SpeechGenerationModel) { self.model = model }
    var sampleRate: Int { model.sampleRate }

    func synthesize(_ job: SynthesisJob, reference: MaterializedArray?, parameters: ResolvedParameters) async throws -> MLXArray {
        try await model.generate(
            text: job.text, voice: job.voice?.preset, refAudio: reference,
            refText: reference == nil ? nil : job.voice?.referenceText, language: job.language,
            generationParameters: parameters.generateParameters(base: model.defaultGenerationParameters))
    }
}

final class Zonos3Engine: MLXSpeechEngine {
    let model: Zonos3Model
    init(_ model: Zonos3Model) { self.model = model }
    var sampleRate: Int { model.sampleRate }

    func synthesize(_ job: SynthesisJob, reference: MaterializedArray?, parameters: ResolvedParameters) async throws -> MLXArray {
        var options = Zonos3Options()
        if let v = parameters.float("speed") { options.speed = v }
        if let v = parameters.float("speaker_cfg_scale") { options.speakerCFGScale = v }
        // A reference replaces the preset; "none" is the model's own word for "no speaker prompt".
        let voice = reference == nil ? (job.voice?.preset ?? "none") : nil
        return try await model.generate(
            text: job.text, voice: voice, refAudio: reference, language: job.language,
            generationParameters: parameters.generateParameters(base: model.defaultGenerationParameters), options: options)
    }
}

// MARK: - Speech to text

final class WhisperEngine: MLXTranscriptionEngine {
    let model: WhisperModel
    /// The Swift port has no language detection: without a language it leaves the language token out of the
    /// prompt. large-v3 turbo copes with that (verified on en/es/fr/de/it/ja/zh); large-v3 returns nothing
    /// and tiny returns garbage, so those need the language spelled out.
    let transcribesWithoutLanguage: Bool
    init(_ model: WhisperModel) {
        self.model = model
        transcribesWithoutLanguage = model.config.decoderLayers <= 4 && model.config.encoderLayers >= 32
    }
    var sampleRate: Int { model.sampleRate }

    func transcribe(_ audio: MLXArray, job: TranscriptionJob, parameters: ResolvedParameters) throws -> Transcript {
        if job.language == nil, !transcribesWithoutLanguage {
            throw EngineError.unsupported(
                "This Whisper model needs the spoken language in the MLX Swift backend; choose one, or use large-v3 turbo.")
        }
        let d = model.defaultGenerationParameters
        let p = STTGenerateParameters(
            maxTokens: d.maxTokens, temperature: parameters.float("temperature") ?? 0, topP: d.topP, topK: d.topK,
            verbose: false, language: job.language, chunkDuration: d.chunkDuration, minChunkDuration: d.minChunkDuration,
            repetitionPenalty: d.repetitionPenalty, repetitionContextSize: d.repetitionContextSize,
            task: parameters.string("task") ?? "transcribe")
        return makeTranscript(model.generate(audio: audio, generationParameters: p), audio: audio, sampleRate: sampleRate)
    }
}

final class ParakeetEngine: MLXTranscriptionEngine {
    let model: any STTGenerationModel
    init(_ model: any STTGenerationModel) { self.model = model }
    var sampleRate: Int { model.sampleRate }

    func transcribe(_ audio: MLXArray, job: TranscriptionJob, parameters: ResolvedParameters) throws -> Transcript {
        let d = model.defaultGenerationParameters
        let chunk = parameters.float("chunk_duration") ?? d.chunkDuration
        let p = STTGenerateParameters(
            maxTokens: d.maxTokens, temperature: d.temperature, topP: d.topP, topK: d.topK, verbose: false,
            language: d.language, chunkDuration: chunk, minChunkDuration: d.minChunkDuration)
        var transcript = makeTranscript(model.generate(audio: audio, generationParameters: p), audio: audio, sampleRate: sampleRate)
        transcript.language = job.language  // Parakeet doesn't report the language it heard.
        return transcript
    }
}

private func makeTranscript(_ output: STTOutput, audio: MLXArray, sampleRate: Int) -> Transcript {
    func seconds(_ any: Any?) -> Double? {
        switch any {
        case let v as Double: v
        case let v as Float: Double(v)
        case let v as Int: Double(v)
        case let v as NSNumber: v.doubleValue
        default: nil
        }
    }
    let segments = (output.segments ?? []).enumerated().compactMap { index, raw -> Transcript.Segment? in
        guard let start = seconds(raw["start"]), let end = seconds(raw["end"]) else { return nil }
        let text = (raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Transcript.Segment(id: index, start: start, end: max(start, end), text: text)
    }
    return Transcript(
        text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
        language: output.language,
        duration: Double(audio.dim(0)) / Double(sampleRate),
        segments: segments.enumerated().map { i, s in
            Transcript.Segment(id: i, start: s.start, end: s.end, text: s.text)
        })
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
