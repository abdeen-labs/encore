import Foundation

extension EncoreService {
    /// Text to speech: plans the script (pronunciations, pause tags, voice-switch tags, chunks that fit the model),
    /// synthesizes chunk by chunk in the right voice, joins everything with the planned gaps and pauses, applies
    /// post-processing, writes the master and records it in history.
    public func speak(_ request: SpeechRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        stream { continuation in
            let started = Date()
            let manifest = try self.manifest(request.modelID, for: .tts)
            guard !request.text.trimmed().isEmpty else { throw ServiceError.emptyScript }
            if manifest.engine == "omnivoice", let instruct = request.instruct?.trimmed(), !instruct.isEmpty,
               let problem = OmniVoiceAttributes.problem(with: instruct) {
                throw ServiceError.invalidRequest(problem)
            }
            let context = try self.loadContext(manifest, variantID: request.variantID)
            let plan = ScriptPlanner(request: request, manifest: manifest, library: await self.libraryVoices(),
                                     pronunciations: self.pronunciations.enabledEntries()).plan(request.text)
            try Self.check(plan)
            let selections = Self.voiceSelections(in: plan, default: request.voice)
            for s in selections { try self.validate(s, for: manifest) }
            let needs = Self.speechNeeds(manifest, selections: selections, instruct: request.instruct)
            let candidates = try await self.capableBackends(for: manifest, needs: needs)

            let title = request.title ?? Self.title(from: plan.parsed.speechText, fallback: "Speech")
            let record = try await self.runtime.run(.speech, title: title, model: manifest) { job in
                let report = Reporter(job: job, continuation: continuation, stageEvent: { .stage($0) }, progressEvent: { .progress($0) })
                let temp = TempFiles(in: self.scratchDirectory)
                defer { temp.cleanup() }
                let session = EngineSession(candidates: candidates, context: context, job: job,
                                            feature: needs.contains(.cloning) ? .cloning : .speech) { await report.stage($0) }
                let voices = VoiceResolver(service: self, manifest: manifest, job: job, temp: temp)
                let settings = SpeechSettings(modelID: manifest.id, instruct: request.instruct, language: request.language,
                                              parameters: request.parameters)
                let audio = try await self.render(plan, voice: request.voice, settings: settings, session: session, voices: voices,
                                                  report: report, progress: 0...0.9)
                let processed = try await self.postProcess(audio, request.post, report: report)
                await report.stage("Saving")
                let main = try await voices.resolve(request.voice)
                return try await self.commit(processed, save: request.saveToHistory) { url in
                    GenerationRecord(kind: .speech, title: title, text: request.text, modelID: manifest.id, modelName: manifest.name,
                                     voiceName: main.name, voiceID: main.libraryID,
                                     parameters: manifest.defaultParameters.merging(request.parameters) { $1 },
                                     audioPath: url.path, duration: processed.duration, sampleRate: processed.sampleRate,
                                     elapsed: Date().timeIntervalSince(started), variantID: context.variant.id,
                                     language: request.language, instruct: request.instruct.flatMap { $0.trimmed().isEmpty ? nil : $0 },
                                     post: request.post, runtime: session.runtime)
                }
            }
            await self.noteUsed(manifest.id, for: selections.contains { if case .library = $0 { true } else { false } } ? .cloning : .speech)
            continuation.yield(.progress(1))
            continuation.yield(.finished(record))
        }
    }

    // MARK: - Shared pieces

    struct SpeechSettings: Sendable {
        var modelID: String
        var instruct: String?
        var language: String?
        var parameters: ParamValues
    }

    static func check(_ plan: ScriptPlan) throws {
        if !plan.parsed.unknownVoiceNames.isEmpty { throw ServiceError.unknownVoiceTags(plan.parsed.unknownVoiceNames) }
        if let error = plan.issues.first(where: { $0.severity == .error }) { throw ServiceError.scriptProblem(error.message) }
        if plan.chunks.isEmpty { throw ServiceError.emptyScript }
    }

    static func voiceSelections(in plan: ScriptPlan, default voice: VoiceSelection) -> [VoiceSelection] {
        var seen: [VoiceSelection] = []
        for c in plan.chunks {
            let s = c.voice ?? voice
            if !seen.contains(s) { seen.append(s) }
        }
        return seen
    }

    /// What a backend must support to speak this.
    static func speechNeeds(_ manifest: ModelManifest, selections: [VoiceSelection], instruct: String?) -> EngineFeatures {
        var needs: EngineFeatures = .synthesis
        let cloning = selections.contains { if case .library = $0 { true } else { false } }
        if cloning { needs.insert(.cloning) }
        // A description with no voice is voice design on models that design (VoxCPM2, Qwen3 VoiceDesign, OmniVoice);
        // on models with a style instruction (Qwen3 CustomVoice) it's just a style hint.
        let described = !(instruct ?? "").trimmed().isEmpty
        if described, !cloning, manifest.capabilities.voiceDesign, !manifest.capabilities.styleInstruction { needs.insert(.voiceDesign) }
        return needs
    }

    /// Synthesizes every chunk of a plan and joins them with the planned silences, at the first chunk's sample rate.
    func render(_ plan: ScriptPlan, voice: VoiceSelection, settings: SpeechSettings, session: EngineSession, voices: VoiceResolver,
                report: Reporter<GenerationEvent>, progress range: ClosedRange<Double>,
                stageLabel: ((Int, Int) -> String)? = nil) async throws -> AudioBuffer {
        let chunks = plan.chunks
        let totalCharacters = Double(max(1, chunks.reduce(0) { $0 + $1.text.count }))
        var done = 0.0
        var assembler = Assembler()
        var index = 0
        for item in plan.items {
            try Task.checkCancellation()
            switch item {
            case .pause(let seconds, _):
                assembler.appendSilence(seconds)
            case .speech(let chunk):
                index += 1
                let resolved = try await voices.resolve(chunk.voice ?? voice)
                let job = SynthesisJob(modelID: settings.modelID, text: chunk.text, voice: resolved.engine,
                                       instruct: resolved.isReference ? nil : settings.instruct,
                                       language: settings.language, parameters: settings.parameters)
                let share = Double(chunk.text.count) / totalCharacters
                let lo = range.lowerBound + (range.upperBound - range.lowerBound) * done
                let hi = range.lowerBound + (range.upperBound - range.lowerBound) * (done + share)
                let label = stageLabel?(index, chunks.count) ?? (chunks.count > 1 ? "Generating \(index) of \(chunks.count)" : "Generating")
                let audio = try await session.run { backend in
                    await report.stage(label)
                    return try await backend.synthesize(job, progress: report.engineProgress(lo...hi))
                }
                try Task.checkCancellation()
                try assembler.append(audio)
                assembler.appendSilence(chunk.gapAfter)
                done += share
                await report.progress(hi)
            }
        }
        return try assembler.finish(defaultRate: Double(session.context.manifest.sampleRate))
    }

    func postProcess<E>(_ audio: AudioBuffer, _ options: PostProcessingOptions, report: Reporter<E>) async throws -> AudioBuffer {
        try Task.checkCancellation()
        var out = audio
        if options.removeSilence {
            await report.stage("Tightening silences")
            var o = options; o.normalizeLoudness = false
            out = PostProcessor.apply(o, to: out)
        }
        if options.normalizeLoudness {
            await report.stage("Normalizing loudness")
            var o = options; o.removeSilence = false
            out = PostProcessor.apply(o, to: out)
        }
        try Task.checkCancellation()
        return out
    }
}

/// Joins synthesized pieces and silences at one sample rate (the first piece's).
struct Assembler {
    private var parts: [Part] = []
    private var rate: Double?
    private enum Part { case audio(AudioBuffer), silence(TimeInterval) }

    mutating func append(_ audio: AudioBuffer) throws {
        guard !audio.isEmpty else { return }
        if rate == nil { rate = audio.sampleRate }
        parts.append(.audio(audio))
    }

    mutating func appendSilence(_ seconds: TimeInterval) {
        if seconds > 0 { parts.append(.silence(seconds)) }
    }

    func finish(defaultRate: Double) throws -> AudioBuffer {
        let rate = rate ?? defaultRate
        // Each piece was generated on its own, so bring their speech to one level before joining them.
        var pieces: [[Float]] = []
        for case .audio(let a) in parts {
            pieces.append(abs(a.sampleRate - rate) > 0.01 ? try AudioEdit.resample(a, to: rate).samples : a.samples)
        }
        var leveled = ChunkLeveler.level(pieces, sampleRate: rate).makeIterator()
        var samples: [Float] = []
        for part in parts {
            switch part {
            case .audio:
                samples += leveled.next() ?? []
            case .silence(let s):
                samples += repeatElement(0, count: max(0, Int((s * rate).rounded())))
            }
        }
        return AudioBuffer(samples: samples, sampleRate: rate)
    }
}

/// Resolves each voice selection once per request (references trimmed, transcripts fixed up).
final class VoiceResolver: @unchecked Sendable {
    let service: EncoreService
    let manifest: ModelManifest
    let job: RuntimeJob
    let temp: TempFiles
    private var cache: [VoiceSelection: EncoreService.ResolvedVoice] = [:]

    init(service: EncoreService, manifest: ModelManifest, job: RuntimeJob, temp: TempFiles) {
        self.service = service; self.manifest = manifest; self.job = job; self.temp = temp
    }

    func resolve(_ selection: VoiceSelection) async throws -> EncoreService.ResolvedVoice {
        if let hit = cache[selection] { return hit }
        let r = try await service.resolve(selection, for: manifest, job: job, temp: temp)
        cache[selection] = r
        return r
    }
}
