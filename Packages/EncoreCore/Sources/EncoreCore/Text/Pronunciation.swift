import Foundation

/// Applies the user's pronunciation list to text before synthesis.
///
/// - Whole words only, judged with Unicode letter/number/mark classes ("Nguyen" matches in "Nguyen's"
///   but not in "Nguyenville"). Edges written in scripts without spaces (Chinese, Japanese, Thai…) need no boundary.
/// - Case sensitivity per entry; case-insensitive comparison is Unicode-aware.
/// - Longest term first at each position, then left to right; replaced text is never scanned again.
/// - Tag-like spans (`[laugh]`, `<break time="1s"/>`, `[voice: Nguyen]`) are copied untouched.
/// - Whitespace inside a term matches any single whitespace character; straight and curly apostrophes match each other.
public struct PronunciationApplier: Sendable {
    struct Rule: Sendable {
        var term: [Character]
        var folded: [String]
        var replacement: String
        var caseSensitive: Bool
        var checkLeft: Bool
        var checkRight: Bool
    }

    private var buckets: [String: [Rule]] = [:]

    public init(entries: [PronunciationEntry]) {
        for e in entries where e.enabled {
            let term = Array(e.term.trimmed())
            guard let first = term.first, let last = term.last else { continue }
            let rule = Rule(term: term, folded: term.map(Self.fold), replacement: e.replacement, caseSensitive: e.caseSensitive,
                            checkLeft: TextClass.isWordCharacter(first) && !TextClass.isNoSpaceScript(first),
                            checkRight: TextClass.isWordCharacter(last) && !TextClass.isNoSpaceScript(last))
            buckets[rule.folded[0], default: []].append(rule)
        }
        for k in buckets.keys { buckets[k]!.sort { $0.term.count > $1.term.count } }
    }

    public var isEmpty: Bool { buckets.isEmpty }

    public func apply(to text: String) -> String {
        guard !buckets.isEmpty, !text.isEmpty else { return text }
        let chars = Array(text)
        let folded = chars.map(Self.fold)
        let n = chars.count

        // Protected offsets from tag ranges.
        var protectedEnd = [Int?](repeating: nil, count: n)
        let tags = TagLexer.scan(text)
        if !tags.isEmpty {
            var offset = 0
            var i = text.startIndex
            var t = 0
            var tagStartOffset: Int?
            while i < text.endIndex, t < tags.count {
                if i == tags[t].range.lowerBound { tagStartOffset = offset }
                i = text.index(after: i); offset += 1
                if i == tags[t].range.upperBound, let s = tagStartOffset {
                    protectedEnd[s] = offset; tagStartOffset = nil; t += 1
                }
            }
        }

        var out = ""
        out.reserveCapacity(text.utf8.count)
        var p = 0
        outer: while p < n {
            if let end = protectedEnd[p] {
                out.append(contentsOf: String(chars[p..<end])); p = end; continue
            }
            if let rules = buckets[folded[p]] {
                for r in rules where p + r.term.count <= n {
                    if r.checkLeft, p > 0, Self.joins(chars[p - 1]) { continue }
                    let end = p + r.term.count
                    if r.checkRight, end < n, Self.joins(chars[end]) { continue }
                    var ok = true
                    for k in 0..<r.term.count {
                        let a = chars[p + k], b = r.term[k]
                        if b.isWhitespace { if !a.isWhitespace { ok = false; break }; continue }
                        if r.caseSensitive ? !Self.same(a, b) : folded[p + k] != r.folded[k] { ok = false; break }
                        if (p + k) > p, protectedEnd[p + k] != nil { ok = false; break }
                    }
                    if ok { out.append(r.replacement); p = end; continue outer }
                }
            }
            out.append(chars[p]); p += 1
        }
        return out
    }

    /// Whether a neighbouring character continues the word (so a match here isn't a whole word).
    private static func joins(_ c: Character) -> Bool { TextClass.isWordCharacter(c) && !TextClass.isNoSpaceScript(c) }

    private static func same(_ a: Character, _ b: Character) -> Bool { a == b || (isApostrophe(a) && isApostrophe(b)) }
    private static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "’" || c == "‘" }
    static func fold(_ c: Character) -> String { isApostrophe(c) ? "'" : String(c).lowercased() }
}
