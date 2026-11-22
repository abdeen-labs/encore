import Foundation
import NaturalLanguage

/// Names the language of a text with Apple's recognizer.
public enum LanguageGuess {
    /// The text's language as a two-letter code ("en", "zh", "no"), or nil when the text is short or the guess is
    /// unsure. With `among`, only those codes count, and the likeliest of them wins.
    public static func code(for text: String, among codes: Set<String>? = nil) -> String? {
        guard text.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
            .map { (code: shortCode($0.key), confidence: $0.value) }
            .filter { codes?.contains($0.code) ?? true }
            .sorted { $0.confidence > $1.confidence }
        guard let best = hypotheses.first, best.confidence > 0.5 else { return nil }
        return best.code
    }

    /// "zh-Hans" → "zh"; Norwegian Bokmål and Nynorsk → "no", the code models use.
    static func shortCode(_ language: NLLanguage) -> String {
        let code = language.rawValue.split(separator: "-").first.map(String.init) ?? language.rawValue
        return code == "nb" || code == "nn" ? "no" : code
    }
}
