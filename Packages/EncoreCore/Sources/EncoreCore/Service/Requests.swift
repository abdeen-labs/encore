import Foundation

// Request and result types for the service layer. All Codable, so a local HTTP API can
// later accept and return them as JSON without translation.

public enum VoiceSelection: Codable, Sendable, Hashable {
    /// The model's default voice.
    case automatic
    /// A voice built into the model.
    case preset(String)
    /// A voice from the user's library.
    case library(UUID)
}

public struct PostProcessingOptions: Codable, Sendable, Hashable {
    /// Trim leading/trailing silence and shorten long internal gaps.
    public var removeSilence: Bool = false
    /// Internal silences longer than this are shortened to it.
    public var maxSilenceSeconds: Double = 0.6
    public var normalizeLoudness: Bool = true
    /// Integrated loudness target in LUFS.
    public var targetLUFS: Double = -16
    public init() {}
}

public struct SpeechRequest: Codable, Sendable {
    public var modelID: String
    public var variantID: String?
    public var text: String
    public var voice: VoiceSelection = .automatic
    public var instruct: String?
    public var language: String?
    public var parameters: ParamValues = [:]
    public var post = PostProcessingOptions()
    /// Split long text at sentence boundaries to fit the model.
    public var autoChunk: Bool = true
    public var applyPronunciations: Bool = true
    /// Silence inserted between auto-chunks, seconds.
    public var chunkGapSeconds: Double = 0.15
    public var title: String?

    public init(modelID: String, text: String) { self.modelID = modelID; self.text = text }
}

public struct TranscriptionRequest: Codable, Sendable {
    public var modelID: String
    public var variantID: String?
    /// Any audio or video file.
    public var mediaPath: String
    public var language: String?
    public var timestamps: TimestampGranularity = .segment
    public var parameters: ParamValues = [:]

    public init(modelID: String, mediaPath: String) { self.modelID = modelID; self.mediaPath = mediaPath }
}

public struct VoiceConversionRequest: Codable, Sendable {
    public var modelID: String
    public var variantID: String?
    public var sourcePath: String
    public var voice: VoiceSelection
    public var parameters: ParamValues = [:]
    public var post = PostProcessingOptions()
    public var title: String?

    public init(modelID: String, sourcePath: String, voice: VoiceSelection) {
        self.modelID = modelID; self.sourcePath = sourcePath; self.voice = voice
    }
}

public struct VoiceDesignRequest: Codable, Sendable {
    public var modelID: String
    public var variantID: String?
    /// "A warm, raspy older British man, slow and deliberate."
    public var description: String
    /// What the candidate clips say. It becomes the reference transcript if a candidate is saved as a voice.
    public var sampleText: String
    public var language: String?
    public var parameters: ParamValues = [:]
    /// Each candidate is a different voice; the user picks one.
    public var candidates: Int = 3

    public init(modelID: String, description: String, sampleText: String) {
        self.modelID = modelID; self.description = description; self.sampleText = sampleText
    }
}

public struct ConversationScript: Codable, Sendable, Hashable {
    public var title: String = ""
    public var speakers: [Speaker] = []
    public var lines: [Line] = []
    public init() {}

    public struct Speaker: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID = UUID()
        public var name: String
        public var voice: VoiceSelection = .automatic
        public init(name: String) { self.name = name }
    }

    public struct Line: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID = UUID()
        public var speakerID: UUID
        public var text: String
        /// Overrides the conversation's default pause after this line, seconds.
        public var pauseAfter: Double?
        public init(speakerID: UUID, text: String) { self.speakerID = speakerID; self.text = text }
    }
}

public struct ConversationRequest: Codable, Sendable {
    public var modelID: String
    public var variantID: String?
    public var script: ConversationScript
    /// Silence between lines, seconds.
    public var pauseSeconds: Double = 0.4
    public var language: String?
    public var parameters: ParamValues = [:]
    public var post = PostProcessingOptions()
    public var applyPronunciations: Bool = true

    public init(modelID: String, script: ConversationScript) { self.modelID = modelID; self.script = script }
}

/// Progress reported while a request runs.
public enum GenerationEvent: Sendable {
    /// Human-readable stage: "Loading model", "Generating 2 of 5", "Normalizing loudness"…
    case stage(String)
    /// Overall fraction complete, 0…1.
    case progress(Double)
    case finished(GenerationRecord)
}

public enum TranscriptionEvent: Sendable {
    case stage(String)
    case progress(Double)
    case finished(TranscriptionRecord)
}

public enum VoiceDesignEvent: Sendable {
    case stage(String)
    case progress(Double)
    /// A candidate clip is ready (WAV on disk), in order.
    case candidate(VoiceDesignCandidate)
    case finished
}

public struct VoiceDesignCandidate: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var audioPath: String
    public var transcript: String
    public var description: String
    public var modelID: String
    public var duration: TimeInterval
    public init(id: UUID = UUID(), audioPath: String, transcript: String, description: String,
                modelID: String, duration: TimeInterval) {
        self.id = id; self.audioPath = audioPath; self.transcript = transcript
        self.description = description; self.modelID = modelID; self.duration = duration
    }
}
