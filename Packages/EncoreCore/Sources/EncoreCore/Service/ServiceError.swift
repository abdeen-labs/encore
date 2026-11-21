import Foundation

/// Something a request needs from a model or backend.
public enum ServiceFeature: String, Codable, Sendable, Hashable, CaseIterable {
    case speech, cloning, voiceDesign, transcription, wordTimestamps, voiceConversion

    public var engineFeature: EngineFeatures {
        switch self {
        case .speech: .synthesis
        case .cloning: .cloning
        case .voiceDesign: .voiceDesign
        case .transcription: .transcription
        case .wordTimestamps: .wordTimestamps
        case .voiceConversion: .voiceConversion
        }
    }

    public static func of(_ features: EngineFeatures) -> [ServiceFeature] {
        allCases.filter { features.contains($0.engineFeature) }
    }

    var phrase: String {
        switch self {
        case .speech: "speech"
        case .cloning: "voice cloning"
        case .voiceDesign: "voice design"
        case .transcription: "transcription"
        case .wordTimestamps: "word timestamps"
        case .voiceConversion: "voice conversion"
        }
    }
}

/// Errors the UI can act on. `code` is stable, for the future HTTP API.
public enum ServiceError: LocalizedError, Sendable, Equatable {
    case unknownModel(String)
    /// The model doesn't do this kind of task (e.g. speech from a transcription model).
    case wrongTask(modelID: String, modelName: String, task: ModelTask)
    /// The weights aren't on disk. Carries what the Models screen needs to jump to the download.
    case modelNotDownloaded(modelID: String, variantID: String, modelName: String, variantLabel: String, partial: Bool)
    /// A backend could do it after a setup step (e.g. installing the Python helper).
    case backendNeedsSetup(runtime: EngineRuntime, message: String)
    case backendUnavailable(runtime: EngineRuntime, message: String)
    /// Neither the model nor any available backend can do this.
    case featureUnsupported(modelID: String, modelName: String, feature: ServiceFeature, detail: String?)
    /// A library voice that no longer exists (deleted), or whose reference clip is gone.
    case voiceMissing(String)
    /// A preset name the model doesn't have.
    case unknownPresetVoice(name: String, modelID: String)
    /// `[voice: Name]` tags naming nobody.
    case unknownVoiceTags([String])
    case emptyScript
    case scriptProblem(String)
    case sourceUnreadable(path: String, reason: String)
    /// No downloaded speech-to-text model for an automatic transcription.
    case noTranscriptionModel
    case invalidRequest(String)
    /// The engine itself failed.
    case generationFailed(String)

    public var code: String {
        switch self {
        case .unknownModel: "unknown_model"
        case .wrongTask: "wrong_task"
        case .modelNotDownloaded: "model_not_downloaded"
        case .backendNeedsSetup: "backend_needs_setup"
        case .backendUnavailable: "backend_unavailable"
        case .featureUnsupported: "feature_unsupported"
        case .voiceMissing: "voice_missing"
        case .unknownPresetVoice: "unknown_preset_voice"
        case .unknownVoiceTags: "unknown_voice_tags"
        case .emptyScript: "empty_script"
        case .scriptProblem: "script_problem"
        case .sourceUnreadable: "source_unreadable"
        case .noTranscriptionModel: "no_transcription_model"
        case .invalidRequest: "invalid_request"
        case .generationFailed: "generation_failed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "There's no model called “\(id)”."
        case .wrongTask(_, let name, let task):
            switch task {
            case .tts: "\(name) doesn't generate speech."
            case .stt: "\(name) doesn't transcribe."
            case .voiceConversion: "\(name) doesn't change voices."
            }
        case .modelNotDownloaded(_, _, let name, let variant, let partial):
            partial ? "\(name) (\(variant)) is only partly downloaded. Finish the download in Models."
                : "\(name) (\(variant)) isn't downloaded yet. Download it in Models."
        case .backendNeedsSetup(let runtime, let message): "\(runtime.displayName) needs setting up: \(message)"
        case .backendUnavailable(let runtime, let message): "\(runtime.displayName) isn't available: \(message)"
        case .featureUnsupported(_, let name, let feature, let detail):
            "\(name) can't do \(feature.phrase) here." + (detail.map { " \($0)" } ?? "")
        case .voiceMissing(let what): "\(what) couldn't be found. It may have been deleted."
        case .unknownPresetVoice(let name, _): "This model has no voice called “\(name)”."
        case .unknownVoiceTags(let names):
            "No voice named " + names.map { "“\($0)”" }.joined(separator: ", ") + ". Fix the [voice:] tag or add the voice to your library."
        case .emptyScript: "There's nothing to say. Type some text first."
        case .scriptProblem(let m): m
        case .sourceUnreadable(let path, let reason): "Couldn't read \((path as NSString).lastPathComponent): \(reason)"
        case .noTranscriptionModel: "Download a transcription model (Whisper or Parakeet) in Models first."
        case .invalidRequest(let m): m
        case .generationFailed(let m): m
        }
    }
}
