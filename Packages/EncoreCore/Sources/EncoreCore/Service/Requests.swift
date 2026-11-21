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
    /// Reuse lines rendered earlier with exactly the same text, voice and settings (only changed lines regenerate).
    public var reuseRenderedLines: Bool = true

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
    /// The seed this candidate was generated with, when the request fixed one.
    public var seed: Int?
    public init(id: UUID = UUID(), audioPath: String, transcript: String, description: String,
                modelID: String, duration: TimeInterval, seed: Int? = nil) {
        self.id = id; self.audioPath = audioPath; self.transcript = transcript
        self.description = description; self.modelID = modelID; self.duration = duration; self.seed = seed
    }
}

// MARK: - Lenient decoding
//
// Request bodies decode with every optional field missing (as an HTTP client would send them); defaults fill in.
// Encoding is unchanged. `VoiceSelection` also accepts the short forms "automatic", {"preset": "af_heart"} and
// {"library": "<uuid>"} besides its synthesized form.

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default value: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? value }
}

extension VoiceSelection {
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            if text == "automatic" || text.isEmpty { self = .automatic; return }
            if let id = UUID(uuidString: text) { self = .library(id); return }
            self = .preset(text); return
        }
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if c.contains(AnyCodingKey("automatic")) { self = .automatic; return }
        if c.contains(AnyCodingKey("preset")) {
            if let name = try? c.decode(String.self, forKey: AnyCodingKey("preset")) { self = .preset(name); return }
            let nested = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("preset"))
            self = .preset(try nested.decode(String.self, forKey: AnyCodingKey("_0"))); return
        }
        if c.contains(AnyCodingKey("library")) {
            if let id = try? c.decode(UUID.self, forKey: AnyCodingKey("library")) { self = .library(id); return }
            let nested = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("library"))
            self = .library(try nested.decode(UUID.self, forKey: AnyCodingKey("_0"))); return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Expected automatic, preset or library"))
    }
}

extension PostProcessingOptions {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PostProcessingOptions()
        removeSilence = try c.value(.removeSilence, default: d.removeSilence)
        maxSilenceSeconds = try c.value(.maxSilenceSeconds, default: d.maxSilenceSeconds)
        normalizeLoudness = try c.value(.normalizeLoudness, default: d.normalizeLoudness)
        targetLUFS = try c.value(.targetLUFS, default: d.targetLUFS)
    }
}

extension SpeechRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(modelID: try c.decode(String.self, forKey: .modelID), text: try c.decode(String.self, forKey: .text))
        variantID = try c.decodeIfPresent(String.self, forKey: .variantID)
        voice = try c.value(.voice, default: voice)
        instruct = try c.decodeIfPresent(String.self, forKey: .instruct)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        parameters = try c.value(.parameters, default: parameters)
        post = try c.value(.post, default: post)
        autoChunk = try c.value(.autoChunk, default: autoChunk)
        applyPronunciations = try c.value(.applyPronunciations, default: applyPronunciations)
        chunkGapSeconds = try c.value(.chunkGapSeconds, default: chunkGapSeconds)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}

extension TranscriptionRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(modelID: try c.decode(String.self, forKey: .modelID), mediaPath: try c.decode(String.self, forKey: .mediaPath))
        variantID = try c.decodeIfPresent(String.self, forKey: .variantID)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        timestamps = try c.value(.timestamps, default: timestamps)
        parameters = try c.value(.parameters, default: parameters)
    }
}

extension VoiceConversionRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(modelID: try c.decode(String.self, forKey: .modelID), sourcePath: try c.decode(String.self, forKey: .sourcePath),
                  voice: try c.decode(VoiceSelection.self, forKey: .voice))
        variantID = try c.decodeIfPresent(String.self, forKey: .variantID)
        parameters = try c.value(.parameters, default: parameters)
        post = try c.value(.post, default: post)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}

extension VoiceDesignRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(modelID: try c.decode(String.self, forKey: .modelID), description: try c.decode(String.self, forKey: .description),
                  sampleText: try c.decode(String.self, forKey: .sampleText))
        variantID = try c.decodeIfPresent(String.self, forKey: .variantID)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        parameters = try c.value(.parameters, default: parameters)
        candidates = try c.value(.candidates, default: candidates)
    }
}

extension ConversationScript {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        title = try c.value(.title, default: title)
        speakers = try c.value(.speakers, default: speakers)
        lines = try c.value(.lines, default: lines)
    }
}

extension ConversationScript.Speaker {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name))
        id = try c.value(.id, default: id)
        voice = try c.value(.voice, default: voice)
    }
}

extension ConversationScript.Line {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(speakerID: try c.decode(UUID.self, forKey: .speakerID), text: try c.decode(String.self, forKey: .text))
        id = try c.value(.id, default: id)
        pauseAfter = try c.decodeIfPresent(Double.self, forKey: .pauseAfter)
    }
}

extension ConversationRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(modelID: try c.decode(String.self, forKey: .modelID), script: try c.decode(ConversationScript.self, forKey: .script))
        variantID = try c.decodeIfPresent(String.self, forKey: .variantID)
        pauseSeconds = try c.value(.pauseSeconds, default: pauseSeconds)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        parameters = try c.value(.parameters, default: parameters)
        post = try c.value(.post, default: post)
        applyPronunciations = try c.value(.applyPronunciations, default: applyPronunciations)
        reuseRenderedLines = try c.value(.reuseRenderedLines, default: reuseRenderedLines)
    }
}

// MARK: - Events as JSON
//
// Events encode as {"type": "stage", "message": …}, {"type": "progress", "fraction": …},
// {"type": "finished", "record": …}, {"type": "candidate", "candidate": …} — ready for a streaming HTTP response.

private enum EventKeys: String, CodingKey { case type, message, fraction, record, candidate }

extension GenerationEvent: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EventKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "stage": self = .stage(try c.decode(String.self, forKey: .message))
        case "progress": self = .progress(try c.decode(Double.self, forKey: .fraction))
        case "finished": self = .finished(try c.decode(GenerationRecord.self, forKey: .record))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown event \(t)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EventKeys.self)
        switch self {
        case .stage(let m): try c.encode("stage", forKey: .type); try c.encode(m, forKey: .message)
        case .progress(let f): try c.encode("progress", forKey: .type); try c.encode(f, forKey: .fraction)
        case .finished(let r): try c.encode("finished", forKey: .type); try c.encode(r, forKey: .record)
        }
    }
}

extension TranscriptionEvent: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EventKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "stage": self = .stage(try c.decode(String.self, forKey: .message))
        case "progress": self = .progress(try c.decode(Double.self, forKey: .fraction))
        case "finished": self = .finished(try c.decode(TranscriptionRecord.self, forKey: .record))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown event \(t)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EventKeys.self)
        switch self {
        case .stage(let m): try c.encode("stage", forKey: .type); try c.encode(m, forKey: .message)
        case .progress(let f): try c.encode("progress", forKey: .type); try c.encode(f, forKey: .fraction)
        case .finished(let r): try c.encode("finished", forKey: .type); try c.encode(r, forKey: .record)
        }
    }
}

extension VoiceDesignEvent: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EventKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "stage": self = .stage(try c.decode(String.self, forKey: .message))
        case "progress": self = .progress(try c.decode(Double.self, forKey: .fraction))
        case "candidate": self = .candidate(try c.decode(VoiceDesignCandidate.self, forKey: .candidate))
        case "finished": self = .finished
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown event \(t)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EventKeys.self)
        switch self {
        case .stage(let m): try c.encode("stage", forKey: .type); try c.encode(m, forKey: .message)
        case .progress(let f): try c.encode("progress", forKey: .type); try c.encode(f, forKey: .fraction)
        case .candidate(let x): try c.encode("candidate", forKey: .type); try c.encode(x, forKey: .candidate)
        case .finished: try c.encode("finished", forKey: .type)
        }
    }
}
