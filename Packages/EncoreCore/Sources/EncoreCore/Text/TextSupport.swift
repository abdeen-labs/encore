import Foundation

/// Character classification shared by the parser, chunker and pronunciation matcher.
enum TextClass {
    /// Scripts written without spaces between words (Han, kana, Thai, Lao, Khmer, Myanmar, Tibetan),
    /// plus CJK punctuation and fullwidth forms.
    static func isNoSpaceScript(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x0E00...0x0EFF,            // Thai, Lao
             0x0F00...0x0FFF,            // Tibetan
             0x1000...0x109F,            // Myanmar
             0x1780...0x17FF,            // Khmer
             0x2E80...0x2FFF,            // CJK radicals, Kangxi
             0x3000...0x30FF,            // CJK punctuation, Hiragana, Katakana
             0x3100...0x312F, 0x31A0...0x31FF, // Bopomofo, Katakana ext
             0x3400...0x4DBF, 0x4E00...0x9FFF, // Han
             0xF900...0xFAFF,            // Compatibility ideographs
             0xFF00...0xFFEF,            // Fullwidth/halfwidth forms
             0x20000...0x3FFFF:          // Han extensions
            return true
        default:
            return false
        }
    }

    /// Letters, digits, combining marks and connector punctuation — what counts as "inside a word".
    static func isWordCharacter(_ c: Character) -> Bool {
        if c == "_" { return true }
        for s in c.unicodeScalars {
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark,
                 .connectorPunctuation:
                return true
            default:
                continue
            }
        }
        return false
    }

    static func isLowercaseLetter(_ c: Character) -> Bool { c.isLetter && c.isLowercase && !c.isUppercase }
    static func isUppercaseLetter(_ c: Character) -> Bool { c.isLetter && c.isUppercase }
}

extension StringProtocol {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension String {
    /// The sub-range of `range` with leading and trailing whitespace/newlines removed. Empty when nothing remains.
    func trimmedRange(_ range: Range<Index>) -> Range<Index> {
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi, self[lo].isWhitespace { lo = index(after: lo) }
        while hi > lo {
            let prev = index(before: hi)
            if self[prev].isWhitespace { hi = prev } else { break }
        }
        return lo..<hi
    }

    /// Collapses every run of whitespace (newlines included) to one space and trims the ends.
    func collapsingWhitespace() -> String {
        var out = ""
        out.reserveCapacity(utf8.count)
        var pendingSpace = false
        for c in self {
            if c.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(c)
            }
        }
        return out
    }
}
