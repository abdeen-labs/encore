import Foundation

public enum EngineRuntime: String, Codable, Sendable, CaseIterable {
    /// In-process, MLX Swift.
    case mlxSwift
    /// The bundled Python helper process (mlx-audio).
    case python
}

public enum BackendAvailability: Sendable, Equatable {
    case ready
    /// Usable after a setup step the app can explain (e.g. the Python environment is not installed).
    case needsSetup(String)
    case unavailable(String)
}

/// Everything a backend needs to load one model variant. Weights are already on disk.
public struct ModelLoadContext: Sendable {
    public var manifest: ModelManifest
    public var variant: ModelVariant
    /// Repo id → local snapshot directory in the Hugging Face cache.
    public var repoDirectories: [String: URL]

    public init(manifest: ModelManifest, variant: ModelVariant, repoDirectories: [String: URL]) {
        self.manifest = manifest
        self.variant = variant
        self.repoDirectories = repoDirectories
    }
    public var primaryDirectory: URL? { repoDirectories[variant.repo] }
}

/// A voice as the engine sees it: a built-in preset, or reference audio to clone.
public struct EngineVoice: Sendable, Equatable {
    public var preset: String?
    public var referenceAudio: URL?
    public var referenceText: String?

    public init(preset: String? = nil, referenceAudio: URL? = nil, referenceText: String? = nil) {
        self.preset = preset
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
    }
}

/// One pass of text through a TTS model. Chunking, pauses and post-processing happen above the engine.
public struct SynthesisJob: Sendable {
    public var modelID: String
    public var text: String
    public var voice: EngineVoice?
    /// Voice description (voice design) or style instruction, for models that take one.
    public var instruct: String?
    public var language: String?
    public var parameters: ParamValues

    public init(modelID: String, text: String, voice: EngineVoice? = nil, instruct: String? = nil,
                language: String? = nil, parameters: ParamValues = [:]) {
        self.modelID = modelID; self.text = text; self.voice = voice
        self.instruct = instruct; self.language = language; self.parameters = parameters
    }
}

public struct TranscriptionJob: Sendable {
    public var modelID: String
    /// 16 kHz mono WAV prepared by the service layer.
    public var audio: URL
    public var language: String?
    public var timestamps: TimestampGranularity
    public var parameters: ParamValues

    public init(modelID: String, audio: URL, language: String? = nil,
                timestamps: TimestampGranularity = .segment, parameters: ParamValues = [:]) {
        self.modelID = modelID; self.audio = audio; self.language = language
        self.timestamps = timestamps; self.parameters = parameters
    }
}

public struct VoiceConversionJob: Sendable {
    public var modelID: String
    /// Source speech (WAV), already cut to a chunk the model can take in one pass.
    public var source: URL
    public var target: EngineVoice
    public var parameters: ParamValues

    public init(modelID: String, source: URL, target: EngineVoice, parameters: ParamValues = [:]) {
        self.modelID = modelID; self.source = source; self.target = target; self.parameters = parameters
    }
}

/// What a backend can do with a given engine key.
public struct EngineFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let synthesis = EngineFeatures(rawValue: 1 << 0)
    public static let cloning = EngineFeatures(rawValue: 1 << 1)
    public static let voiceDesign = EngineFeatures(rawValue: 1 << 2)
    public static let transcription = EngineFeatures(rawValue: 1 << 3)
    public static let wordTimestamps = EngineFeatures(rawValue: 1 << 4)
    public static let voiceConversion = EngineFeatures(rawValue: 1 << 5)
}

/// Fraction complete in 0…1, when the engine can tell.
public typealias EngineProgress = @Sendable (Double) -> Void

/// A place models run. There is one backend per runtime. For each request the service layer picks
/// the first backend (MLX Swift, then Python, unless the user prefers otherwise) whose
/// `engineFeatures()[manifest.engine]` covers what the request needs. Calls honor task cancellation.
public protocol EngineBackend: AnyObject, Sendable {
    var runtime: EngineRuntime { get }
    /// Engine key (`ModelManifest.engine`) → what this backend can do with it.
    func engineFeatures() async -> [String: EngineFeatures]
    func availability() async -> BackendAvailability
    func load(_ context: ModelLoadContext) async throws
    func unload(modelID: String) async
    func loadedModelIDs() async -> [String]
    func synthesize(_ job: SynthesisJob, progress: EngineProgress?) async throws -> AudioBuffer
    func transcribe(_ job: TranscriptionJob, progress: EngineProgress?) async throws -> Transcript
    func convertVoice(_ job: VoiceConversionJob, progress: EngineProgress?) async throws -> AudioBuffer
}

public enum EngineError: LocalizedError, Sendable {
    case unsupported(String)
    case modelNotLoaded(String)
    case backendUnavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let m): m
        case .modelNotLoaded(let id): "The model \(id) isn't loaded."
        case .backendUnavailable(let m): m
        case .failed(let m): m
        }
    }
}
