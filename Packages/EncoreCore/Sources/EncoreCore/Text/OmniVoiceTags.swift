import Foundation

/// OmniVoice's sound tags. The model learned each tag as the tokens of the tag on its own, so a tag has to be
/// tokenized apart from the words around it. Run together, " [sigh]" becomes " [" + "s" + "igh" + "]", and the model
/// reads the word out loud. These are the tags mlx-audio's Python port splits on (omnivoice.py, `_NONVERBAL_PATTERN`).
public enum OmniVoiceTags {
    public static let all: [String] = [
        "laughter", "sigh", "confirmation-en", "question-en", "question-ah", "question-oh", "question-ei",
        "question-yi", "surprise-ah", "surprise-oh", "surprise-wa", "surprise-yo", "dissatisfaction-hnn",
    ].map { "[\($0)]" }

    private nonisolated(unsafe) static let pattern = try! Regex(
        all.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|"))

    /// `text` cut into runs that are each either one sound tag or the text between tags, in order. Joined, they make
    /// `text` again. Empty for empty text.
    public static func segments(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        for range in text.ranges(of: pattern) {
            if start < range.lowerBound { result.append(text[start..<range.lowerBound]) }
            result.append(text[range])
            start = range.upperBound
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }
}
