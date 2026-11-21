import Foundation

/// How a chunk ends — what kind of gap belongs after it.
public enum ChunkBoundary: String, Sendable, Hashable, Codable, Comparable {
    /// Hard cut inside a word (a single "word" longer than the limit).
    case forced
    case word
    case clause
    case sentence
    /// A blank line: a natural place for a slightly longer gap.
    case paragraph
    /// The end of the text that was chunked.
    case end

    var rank: Int {
        switch self {
        case .forced: 0
        case .word: 1
        case .clause: 2
        case .sentence: 3
        case .paragraph: 4
        case .end: 5
        }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct TextChunk: Sendable, Hashable {
    /// Exactly `source[range]`: trimmed, original spacing and line breaks kept.
    public var text: String
    public var range: Range<String.Index>
    /// The same range in UTF-16 units.
    public var utf16Range: NSRange
    public var boundary: ChunkBoundary
}

/// Splits long text to fit a model's `maxChunkCharacters`.
///
/// Blank lines always split (and report `.paragraph`). Inside a paragraph, text that fits is one chunk;
/// longer text breaks at sentence ends, else clause punctuation or line breaks, else between words
/// (dictionary-based for scripts without spaces, such as Chinese, Japanese or Thai), and only as a last
/// resort inside a word. Tag-like spans (`[laugh]`, `[pause 1s]`, `<break …/>`) are never split.
/// A tiny last piece is rebalanced with its neighbour. Lengths are counted in characters (grapheme clusters).
public struct TextChunker: Sendable {
    public var maxCharacters: Int

    /// `maxCharacters <= 0` means no limit: only paragraphs split.
    public init(maxCharacters: Int) { self.maxCharacters = maxCharacters }

    public func chunks(of text: String) -> [TextChunk] { chunks(of: text, in: text.startIndex..<text.endIndex) }

    /// Chunks `text[range]`; returned ranges refer to `text`.
    public func chunks(of text: String, in range: Range<String.Index>) -> [TextChunk] {
        let tags = TagLexer.scan(text, in: range).map(\.range)
        var out: [TextChunk] = []
        let paragraphs = Self.paragraphs(in: text, range: range)
        for (pi, para) in paragraphs.enumerated() {
            let pieces = chunkParagraph(text, para, tags: tags)
            for (i, piece) in pieces.enumerated() {
                var boundary = piece.boundary
                if i == pieces.count - 1 { boundary = pi == paragraphs.count - 1 ? .end : .paragraph }
                out.append(TextChunk(text: String(text[piece.range]), range: piece.range,
                                     utf16Range: NSRange(piece.range, in: text), boundary: boundary))
            }
        }
        return out
    }

    // MARK: Paragraphs

    /// Non-empty, trimmed paragraph ranges separated by blank lines (or U+2029).
    static func paragraphs(in text: String, range: Range<String.Index>) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = range.lowerBound
        var i = range.lowerBound
        func emit(_ end: String.Index) {
            let r = text.trimmedRange(start..<end)
            if !r.isEmpty { result.append(r) }
        }
        while i < range.upperBound {
            let c = text[i]
            if c == "\u{2029}" {
                emit(i); i = text.index(after: i); start = i; continue
            }
            if c.isNewline {
                // Look ahead past horizontal whitespace for another newline.
                var j = text.index(after: i)
                while j < range.upperBound, text[j].isWhitespace, !text[j].isNewline { j = text.index(after: j) }
                if j < range.upperBound, text[j].isNewline {
                    emit(i)
                    while j < range.upperBound, text[j].isWhitespace { j = text.index(after: j) }
                    i = j; start = j; continue
                }
            }
            i = text.index(after: i)
        }
        emit(range.upperBound)
        return result
    }

    // MARK: Within a paragraph

    struct Piece { var range: Range<String.Index>; var boundary: ChunkBoundary }

    private func chunkParagraph(_ text: String, _ para: Range<String.Index>, tags: [Range<String.Index>]) -> [Piece] {
        let limit = maxCharacters
        var idx: [String.Index] = []
        var chars: [Character] = []
        var i = para.lowerBound
        while i < para.upperBound { idx.append(i); chars.append(text[i]); i = text.index(after: i) }
        idx.append(para.upperBound)
        let n = chars.count
        if limit <= 0 || n <= limit { return [Piece(range: para, boundary: .end)] }

        let breaks = Self.breakStrengths(text, chars: chars, idx: idx, tags: tags)

        // Offsets of the non-whitespace content [s, e).
        func trimmed(_ s: Int, _ e: Int) -> (Int, Int) {
            var s = s, e = e
            while s < e, chars[s].isWhitespace { s += 1 }
            while e > s, chars[e - 1].isWhitespace { e -= 1 }
            return (s, e)
        }

        var spans: [(Int, Int, ChunkBoundary)] = []
        var start = 0
        while true {
            (start, _) = trimmed(start, n)
            let (_, end) = trimmed(start, n)
            if start >= end { break }
            if end - start <= limit { spans.append((start, end, .end)); break }
            let p = chooseBreak(breaks, from: start, limit: limit, n: n)
            let (s, e) = trimmed(start, p.offset)
            if e > s { spans.append((s, e, p.boundary)) }
            start = p.offset
        }

        // Rebalance a tiny trailing chunk with its neighbour.
        if spans.count >= 2 {
            let last = spans[spans.count - 1], prev = spans[spans.count - 2]
            let minTail = max(1, limit / 4)
            if last.1 - last.0 < minTail {
                let a = prev.0, b = last.1, total = b - a
                let mid = a + total / 2
                var best: (offset: Int, rank: Int, dist: Int)?
                for p in (a + 1)..<b {
                    let strength = breaks[p]
                    guard strength.rank > 0, p - a <= limit, b - p <= limit else { continue }
                    guard p >= a + total / 4, p <= b - total / 4 else { continue }
                    let dist = abs(p - mid)
                    if best == nil || strength.rank > best!.rank || (strength.rank == best!.rank && dist < best!.dist) {
                        best = (p, strength.rank, dist)
                    }
                }
                if let best {
                    let first = trimmed(a, best.offset), second = trimmed(best.offset, b)
                    if first.1 > first.0, second.1 > second.0 {
                        spans.removeLast(2)
                        spans.append((first.0, first.1, breaks[best.offset].boundary))
                        spans.append((second.0, second.1, .end))
                    }
                }
            }
        }
        return spans.map { Piece(range: idx[$0.0]..<idx[$0.1], boundary: $0.2) }
    }

    private func chooseBreak(_ breaks: [BreakStrength], from start: Int, limit: Int, n: Int) -> (offset: Int, boundary: ChunkBoundary) {
        let windowEnd = min(n, start + limit)
        // Prefer the strongest boundary that still leaves a reasonably full chunk.
        let minFill = start + max(1, Int(Double(limit) * 0.4))
        for wanted in [BreakStrength.sentence, .clause, .word] {
            var p = windowEnd
            while p > start {
                if breaks[p].rank >= wanted.rank, p >= minFill || wanted == .word { return (p, breaks[p].boundary) }
                p -= 1
            }
        }
        // No boundary at all: cut at the limit, but never inside a tag.
        var p = windowEnd
        while p > start, breaks[p] == .forbidden { p -= 1 }
        if p == start {
            p = windowEnd
            while p < n, breaks[p] == .forbidden { p += 1 }
        }
        return (p, .forced)
    }

    // MARK: Break analysis

    enum BreakStrength: Equatable {
        case forbidden, none, word, clause, sentence
        var rank: Int {
            switch self {
            case .forbidden, .none: 0
            case .word: 1
            case .clause: 2
            case .sentence: 3
            }
        }
        var boundary: ChunkBoundary {
            switch self {
            case .sentence: .sentence
            case .clause: .clause
            case .word: .word
            case .forbidden, .none: .forced
            }
        }
    }

    static let terminators: Set<Character> = [".", "!", "?", "…", "‽", "⁇", "⁈", "⁉", "。", "！", "？", "｡"]
    static let fullwidthTerminators: Set<Character> = ["。", "！", "？", "｡"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", "»", "›", ")", "]", "}", "」", "』", "）", "】", "》", "〉", "〕"]
    static let clausePunctuation: Set<Character> = [",", ";", ":", "—", "–", "、", "，", "；", "：", "‥"]
    static let fullwidthClausePunctuation: Set<Character> = ["、", "，", "；", "："]

    /// Abbreviations after which a period does not end a sentence.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "mx", "dr", "prof", "rev", "hon", "gen", "col", "capt", "lt", "sgt", "st", "mt", "ft",
        "fr", "sr", "jr", "sen", "rep", "gov", "pres", "messrs", "mme", "mlle", "vs", "etc", "cf", "fig", "figs",
        "no", "nos", "vol", "vols", "pp", "approx", "ca", "dept", "est", "inc", "ltd", "co", "corp", "jan", "feb",
        "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "e.g", "i.e", "a.m", "p.m", "al",
        "op", "ed", "eds", "ch", "sec", "art", "ave", "blvd", "rd", "hwy", "min", "max", "tel", "ext", "dr", "bros",
    ]
    /// Of those, the ones that often do end a sentence ("…and so on, etc. Then…") when a capital follows.
    static let sentenceFinalAbbreviations: Set<String> = ["etc", "inc", "ltd", "co", "corp", "al", "bros"]

    /// `result[p]` = how good a place offset `p` (between chars[p-1] and chars[p]) is to end a chunk.
    static func breakStrengths(_ text: String, chars: [Character], idx: [String.Index], tags: [Range<String.Index>]) -> [BreakStrength] {
        let n = chars.count
        var s = [BreakStrength](repeating: .none, count: n + 1)
        func raise(_ p: Int, _ v: BreakStrength) {
            guard p > 0, p < n, s[p] != .forbidden, v.rank > s[p].rank else { return }
            s[p] = v
        }

        // Words: at whitespace.
        for p in 1..<n where chars[p].isWhitespace != chars[p - 1].isWhitespace { raise(p, .word) }

        // Words in scripts without spaces: ask the system word segmenter.
        if chars.contains(where: TextClass.isNoSpaceScript) {
            let range = idx[0]..<idx[n]
            var offsetOf: [String.Index: Int] = [:]
            offsetOf.reserveCapacity(n + 1)
            for (o, ix) in idx.enumerated() { offsetOf[ix] = o }
            text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, r, _, _ in
                if let a = offsetOf[r.lowerBound] { raise(a, .word) }
                if let b = offsetOf[r.upperBound] { raise(b, .word) }
            }
        }

        // Clauses: punctuation followed by space (or fullwidth punctuation), and single line breaks.
        for p in 0..<n {
            let c = chars[p]
            if c.isNewline { raise(p + 1, .clause); raise(p, .clause); continue }
            if clausePunctuation.contains(c) {
                if fullwidthClausePunctuation.contains(c) || p + 1 == n || chars[p + 1].isWhitespace { raise(p + 1, .clause) }
            }
        }

        // Sentences.
        var p = 0
        while p < n {
            guard terminators.contains(chars[p]) else { p += 1; continue }
            let clusterStart = p
            var j = p
            while j < n, terminators.contains(chars[j]) { j += 1 }
            let cluster = chars[clusterStart..<j]
            while j < n, closers.contains(chars[j]) { j += 1 }
            defer { p = max(j, p + 1) }
            if cluster.contains(where: fullwidthTerminators.contains) { raise(j, .sentence); continue }
            guard j == n || chars[j].isWhitespace else { continue }   // "3.50", "e.g.,", "a.m.)x"
            var k = j
            while k < n, chars[k].isWhitespace { k += 1 }
            if k < n, TextClass.isLowercaseLetter(chars[k]) { continue } // "Really?” she said." / "… and then"
            if cluster.count == 1, cluster.first == "." {
                // The word before the period.
                var w = clusterStart
                while w > 0, !chars[w - 1].isWhitespace, !"([{\"'“‘«".contains(chars[w - 1]) { w -= 1 }
                let word = String(chars[w..<clusterStart])
                let lower = word.lowercased()
                if abbreviations.contains(lower) {
                    if !(sentenceFinalAbbreviations.contains(lower) && k < n && TextClass.isUppercaseLetter(chars[k])) { continue }
                }
                // Initials ("J. R. R. Tolkien") and dotted acronyms ("U.S.", "Ph.D.").
                if word.count == 1, let f = word.first, f.isLetter, f.isUppercase { continue }
                if word.contains("."), word.split(separator: ".").allSatisfy({ $0.count <= 2 && $0.allSatisfy(\.isLetter) }) { continue }
                // A list number at the start of a line: "1. Do this".
                if !word.isEmpty, word.allSatisfy(\.isNumber), w == 0 || chars[w - 1].isNewline { continue }
            }
            raise(j, .sentence)
        }

        // Never inside a tag.
        for t in tags where t.upperBound > idx[0] && t.lowerBound < idx[n] {
            // First offset at or after the tag start (binary search).
            var lo = 0, hi = n
            while lo < hi {
                let mid = (lo + hi) / 2
                if idx[mid] < t.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            var q = lo + 1
            while q < n, idx[q] < t.upperBound { s[q] = .forbidden; q += 1 }
        }
        return s
    }
}
