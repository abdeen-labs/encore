import Foundation

/// Describes one model family: where its weights live, its licence, what it can do,
/// and every generation control it exposes. Manifests are JSON files in
/// `Resources/Manifests`; the UI is rendered from them.
public struct ModelManifest: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var family: String
    public var summary: String
    public var tasks: [ModelTask]
    /// Key that engine backends use to pick their adapter (e.g. "kokoro", "qwen3_tts", "whisper").
    public var engine: String
    public var variants: [ModelVariant]
    public var license: ModelLicense
    public var capabilities: ModelCapabilities
    /// BCP-47-ish codes; empty means "not language specific / auto".
    public var languages: [ModelLanguage]
    public var presetVoices: [PresetVoice]
    /// Inline tags the model itself understands (e.g. `[laugh]`).
    public var expressiveTags: [ExpressiveTag]
    public var parameters: [ParameterSpec]
    public var reference: ReferenceSpec?
    /// Longest text (characters) the model handles well in one pass; longer text is auto-chunked.
    public var maxChunkCharacters: Int
    public var sampleRate: Int
    public var homepage: String?

    public var defaultVariant: ModelVariant { variants.first(where: { $0.recommended == true }) ?? variants[0] }
    public func variant(_ id: String?) -> ModelVariant { variants.first(where: { $0.id == id }) ?? defaultVariant }
    public var defaultParameters: ParamValues {
        Dictionary(uniqueKeysWithValues: parameters.compactMap { p in p.defaultValue.map { (p.key, $0) } })
    }
}

public enum ModelTask: String, Codable, Sendable, CaseIterable {
    case tts, stt, voiceConversion
}

public struct ModelVariant: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    /// e.g. "8-bit", "bf16"
    public var label: String
    /// Primary Hugging Face repo id.
    public var repo: String
    public var revision: String?
    /// Extra repos that must also be present (codecs, tokenizers, companion checkpoints).
    public var companionRepos: [String]?
    /// Glob patterns to download; nil means the whole repo.
    public var allowPatterns: [String]?
    public var downloadBytes: Int64
    /// Rough resident memory once loaded.
    public var memoryBytes: Int64
    public var recommended: Bool?
    /// Glob patterns per companion repo; a companion missing here is downloaded whole.
    /// (`allowPatterns` applies to the primary repo only.)
    public var companionAllowPatterns: [String: [String]]?

    public var allRepos: [String] { [repo] + (companionRepos ?? []) }
}

public struct ModelLicense: Codable, Sendable, Hashable {
    /// SPDX id when there is one, otherwise the licence's own name.
    public var name: String
    public var url: String?
    public var commercialUse: Bool?
    /// One or two plain sentences on what the licence asks of the user.
    public var summary: String?
    /// True when the upstream repo is gated on Hugging Face (as of writing; the hub is re-checked at download time).
    public var gated: Bool?
}

public struct ModelCapabilities: Codable, Sendable, Hashable {
    public var presetVoices: Bool = false
    public var cloning: Bool = false
    /// Cloning quality depends on (or requires) the reference transcript.
    public var cloningUsesTranscript: Bool = false
    /// Can create a voice from a natural-language description (`instruct`, no reference).
    public var voiceDesign: Bool = false
    /// Accepts a style/emotion instruction alongside a voice.
    public var styleInstruction: Bool = false
    public var expressiveTags: Bool = false
    public var nativeDialogue: Bool = false
    public var segmentTimestamps: Bool = false
    public var wordTimestamps: Bool = false

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ k: CodingKeys) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? false }
        presetVoices = flag(.presetVoices); cloning = flag(.cloning)
        cloningUsesTranscript = flag(.cloningUsesTranscript); voiceDesign = flag(.voiceDesign)
        styleInstruction = flag(.styleInstruction); expressiveTags = flag(.expressiveTags)
        nativeDialogue = flag(.nativeDialogue); segmentTimestamps = flag(.segmentTimestamps)
        wordTimestamps = flag(.wordTimestamps)
    }
}

public struct ModelLanguage: Codable, Sendable, Hashable, Identifiable {
    /// The value passed to the engine.
    public var code: String
    public var name: String
    public var id: String { code }
}

public struct PresetVoice: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var language: String?
    public var gender: String?
    public var note: String?
}

public struct ExpressiveTag: Codable, Sendable, Hashable, Identifiable {
    /// Literal text inserted into the script, e.g. "[laugh]".
    public var tag: String
    public var label: String
    public var id: String { tag }
}

public struct ReferenceSpec: Codable, Sendable, Hashable {
    public var minSeconds: Double
    public var maxSeconds: Double
    public var transcript: TranscriptNeed
    public enum TranscriptNeed: String, Codable, Sendable { case required, recommended, unused }
}

public struct ParameterSpec: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var help: String?
    public var type: Kind
    public var tier: Tier
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var unit: String?
    public var options: [Option]?
    public var defaultValue: ParamValue?

    public var id: String { key }
    public enum Kind: String, Codable, Sendable { case float, int, bool, choice, text, seed }
    public enum Tier: String, Codable, Sendable { case basic, advanced }
    public struct Option: Codable, Sendable, Hashable, Identifiable {
        public var value: String
        public var label: String
        public var id: String { value }
    }

    enum CodingKeys: String, CodingKey {
        case key, label, help, type, tier, min, max, step, unit, options
        case defaultValue = "default"
    }
}
