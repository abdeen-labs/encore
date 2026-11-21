import Foundation

/// OmniVoice designs a voice from a comma-separated list of speaker attributes, not from prose: anything else ends up
/// read aloud or ignored. This is the vocabulary k2-fsa documents (docs/voice-design.md in github.com/k2-fsa/OmniVoice):
/// one value per category, case-insensitive, English or Chinese, separated by "," or "，".
public enum OmniVoiceAttributes {
    public struct Category: Sendable {
        public var name: String
        public var english: [String]
        public var chinese: [String]
    }

    public static let categories: [Category] = [
        Category(name: "Gender", english: ["male", "female"], chinese: ["男", "女"]),
        Category(name: "Age", english: ["child", "teenager", "young adult", "middle-aged", "elderly"],
                 chinese: ["儿童", "少年", "青年", "中年", "老年"]),
        Category(name: "Pitch", english: ["very low pitch", "low pitch", "moderate pitch", "high pitch", "very high pitch"],
                 chinese: ["极低音调", "低音调", "中音调", "高音调", "极高音调"]),
        Category(name: "Style", english: ["whisper"], chinese: ["耳语"]),
        Category(name: "English accent", english: ["american accent", "british accent", "australian accent", "canadian accent",
                                                   "indian accent", "chinese accent", "korean accent", "japanese accent",
                                                   "portuguese accent", "russian accent"], chinese: []),
        Category(name: "Chinese dialect", english: [], chinese: ["河南话", "陕西话", "四川话", "贵州话", "云南话", "桂林话",
                                                                "济南话", "石家庄话", "甘肃话", "宁夏话", "青岛话", "东北话"]),
    ]

    /// One line per category, for help text.
    public static var vocabularySummary: String {
        categories.map { c in "\(c.name): \((c.english.isEmpty ? c.chinese : c.english).joined(separator: ", "))" }
            .joined(separator: "\n")
    }

    /// The items of `description`, trimmed and lowercased.
    public static func items(_ description: String) -> [String] {
        description.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Items OmniVoice doesn't know (empty when the description is a valid attribute list).
    public static func unknownItems(in description: String) -> [String] {
        let known = Set(categories.flatMap { $0.english + $0.chinese })
        return items(description).filter { !known.contains($0) }
    }

    /// Nil when `description` is usable; otherwise a message saying what to write instead.
    public static func problem(with description: String) -> String? {
        let unknown = unknownItems(in: description)
        guard !unknown.isEmpty else { return nil }
        let shown = unknown.prefix(2).map { "“\($0.count > 32 ? String($0.prefix(32)) + "…" : $0)”" }.joined(separator: ", ")
        return "OmniVoice builds a voice from attributes, not a description, and doesn't know \(shown). "
            + "Use gender, age, pitch, whisper and accent, separated by commas: “female, young adult, low pitch, british accent”."
    }
}
