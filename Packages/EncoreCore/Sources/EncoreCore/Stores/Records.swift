import Foundation

/// A saved voice: a short reference clip plus its transcript.
public struct Voice: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var tags: [String]
    public var origin: Origin
    /// Exact words spoken in the reference clip.
    public var transcript: String
    public var language: String?
    public var notes: String
    /// The description a designed voice was made from.
    public var designPrompt: String?
    public var sourceModelID: String?
    public var duration: TimeInterval
    public var createdAt: Date
    /// When the user confirmed they have the speaker's permission. Nil for designed voices.
    public var consentConfirmedAt: Date?

    public enum Origin: String, Codable, Sendable { case cloned, designed, imported }

    public init(id: UUID = UUID(), name: String, tags: [String] = [], origin: Origin, transcript: String,
                language: String? = nil, notes: String = "", designPrompt: String? = nil,
                sourceModelID: String? = nil, duration: TimeInterval, createdAt: Date = Date(),
                consentConfirmedAt: Date? = nil) {
        self.id = id; self.name = name; self.tags = tags; self.origin = origin; self.transcript = transcript
        self.language = language; self.notes = notes; self.designPrompt = designPrompt
        self.sourceModelID = sourceModelID; self.duration = duration; self.createdAt = createdAt
        self.consentConfirmedAt = consentConfirmedAt
    }
}

/// One finished piece of audio in the history.
public struct GenerationRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: Kind
    public var title: String
    /// The script, or for voice conversion the source file name.
    public var text: String
    public var modelID: String
    public var modelName: String
    public var voiceName: String?
    public var voiceID: UUID?
    public var parameters: ParamValues
    /// Absolute path of the WAV master.
    public var audioPath: String
    public var duration: TimeInterval
    public var sampleRate: Double
    public var createdAt: Date
    /// Wall-clock seconds the generation took.
    public var elapsed: TimeInterval
    public var favorite: Bool
    // Added later; nil in records written before they existed.
    /// The model variant it was made with.
    public var variantID: String?
    /// The language asked for (nil: the model's default / automatic).
    public var language: String?
    /// Style direction or voice description sent to the model.
    public var instruct: String?
    /// Post-processing applied to the result.
    public var post: PostProcessingOptions?
    /// Where the model ran.
    public var runtime: EngineRuntime?

    public enum Kind: String, Codable, Sendable, CaseIterable { case speech, conversation, voiceChange, voiceDesign }

    public init(id: UUID = UUID(), kind: Kind, title: String, text: String, modelID: String, modelName: String,
                voiceName: String? = nil, voiceID: UUID? = nil, parameters: ParamValues = [:], audioPath: String,
                duration: TimeInterval, sampleRate: Double, createdAt: Date = Date(), elapsed: TimeInterval = 0,
                favorite: Bool = false, variantID: String? = nil, language: String? = nil, instruct: String? = nil,
                post: PostProcessingOptions? = nil, runtime: EngineRuntime? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.modelID = modelID
        self.modelName = modelName; self.voiceName = voiceName; self.voiceID = voiceID
        self.parameters = parameters; self.audioPath = audioPath; self.duration = duration
        self.sampleRate = sampleRate; self.createdAt = createdAt; self.elapsed = elapsed; self.favorite = favorite
        self.variantID = variantID; self.language = language; self.instruct = instruct; self.post = post
        self.runtime = runtime
    }

    public var audioURL: URL { URL(fileURLWithPath: audioPath) }
}

public struct TranscriptionRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var sourceName: String
    public var sourcePath: String
    public var modelID: String
    public var modelName: String
    public var transcript: Transcript
    public var createdAt: Date
    public var elapsed: TimeInterval
    // Added later; nil in records written before they existed.
    public var variantID: String?
    /// The language asked for (nil: detected).
    public var language: String?
    public var timestamps: TimestampGranularity?
    public var parameters: ParamValues?
    public var runtime: EngineRuntime?

    public init(id: UUID = UUID(), sourceName: String, sourcePath: String, modelID: String, modelName: String,
                transcript: Transcript, createdAt: Date = Date(), elapsed: TimeInterval = 0, variantID: String? = nil,
                language: String? = nil, timestamps: TimestampGranularity? = nil, parameters: ParamValues? = nil,
                runtime: EngineRuntime? = nil) {
        self.id = id; self.sourceName = sourceName; self.sourcePath = sourcePath; self.modelID = modelID
        self.modelName = modelName; self.transcript = transcript; self.createdAt = createdAt; self.elapsed = elapsed
        self.variantID = variantID; self.language = language; self.timestamps = timestamps
        self.parameters = parameters; self.runtime = runtime
    }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.transcript == b.transcript }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Saved generation settings for one model.
public struct Preset: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var modelID: String
    public var parameters: ParamValues
    public var post: PostProcessingOptions
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, modelID: String, parameters: ParamValues,
                post: PostProcessingOptions = .init(), createdAt: Date = Date()) {
        self.id = id; self.name = name; self.modelID = modelID; self.parameters = parameters
        self.post = post; self.createdAt = createdAt
    }
}

/// "Say this word like that." Applied to text before synthesis.
public struct PronunciationEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var term: String
    /// Respelling the model reads instead, e.g. "Nguyen" → "win".
    public var replacement: String
    public var caseSensitive: Bool
    public var enabled: Bool

    public init(id: UUID = UUID(), term: String, replacement: String, caseSensitive: Bool = false, enabled: Bool = true) {
        self.id = id; self.term = term; self.replacement = replacement
        self.caseSensitive = caseSensitive; self.enabled = enabled
    }
}
