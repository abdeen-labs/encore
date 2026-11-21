import Foundation

public enum TranscriptFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case text, timestampedText, srt, vtt, json

    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .text, .timestampedText: "txt"
        case .srt: "srt"
        case .vtt: "vtt"
        case .json: "json"
        }
    }
    public var label: String {
        switch self {
        case .text: "Plain text"
        case .timestampedText: "Text with timestamps"
        case .srt: "SubRip subtitles (.srt)"
        case .vtt: "WebVTT subtitles (.vtt)"
        case .json: "JSON"
        }
    }
}

/// Renders a `Transcript` as text, timestamped text, SRT, WebVTT or JSON.
///
/// Subtitles follow common broadcast practice: at most `maxLineLength` characters per line (CJK characters
/// count double) and `maxLines` lines per cue. Long segments are split into several cues, at word timings
/// when the transcript has them, otherwise at times interpolated by character position.
public struct TranscriptFormatter: Sendable {
    public var maxLineLength = 42
    public var maxLines = 2
    /// Cues longer than this are split even when the text would fit.
    public var maxCueDuration: TimeInterval = 7
    /// Include word timings in JSON when the transcript has them.
    public var includeWords = true

    public init() {}

    public func string(_ t: Transcript, as format: TranscriptFormat) -> String {
        switch format {
        case .text: plainText(t)
        case .timestampedText: timestampedText(t)
        case .srt: srt(t)
        case .vtt: vtt(t)
        case .json: json(t)
        }
    }

    public func data(_ t: Transcript, as format: TranscriptFormat) -> Data { Data(string(t, as: format).utf8) }

    // MARK: Text

    public func plainText(_ t: Transcript) -> String {
        let text = t.text.trimmed()
        if !text.isEmpty { return text + "\n" }
        return Self.join(t.segments.map { $0.text.trimmed() }).trimmed() + "\n"
    }

    /// `[00:01:23] Text of the segment` — one line per segment. Hours are shown only when the audio needs them.
    public func timestampedText(_ t: Transcript) -> String {
        guard !t.segments.isEmpty else { return plainText(t) }
        let hours = (t.duration ?? t.segments.last?.end ?? 0) >= 3600
        return t.segments.map { "[\(Self.clock($0.start, hours: hours))] \($0.text.collapsingWhitespace())" }
            .joined(separator: "\n") + "\n"
    }

    // MARK: Subtitles

    public struct Cue: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var lines: [String]
    }

    public func srt(_ t: Transcript) -> String {
        cues(t).enumerated().map { i, c in
            "\(i + 1)\n\(Self.srtTime(c.start)) --> \(Self.srtTime(c.end))\n\(c.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    public func vtt(_ t: Transcript) -> String {
        var out = "WEBVTT\n"
        for c in cues(t) {
            let lines = c.lines.map {
                $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            out += "\n\(Self.vttTime(c.start)) --> \(Self.vttTime(c.end))\n\(lines.joined(separator: "\n"))\n"
        }
        return out
    }

    /// Subtitle cues for a transcript, in order, non-overlapping.
    public func cues(_ t: Transcript) -> [Cue] {
        var segments = t.segments
        if segments.isEmpty, !t.text.trimmed().isEmpty {
            segments = [.init(id: 0, start: 0, end: t.duration ?? max(1, Double(t.text.count) / 15), text: t.text)]
        }
        var cues: [Cue] = []
        for seg in segments {
            for piece in split(seg) where !piece.text.isEmpty {
                cues.append(Cue(start: piece.start, end: max(piece.end, piece.start + 0.2), lines: wrap(piece.text)))
            }
        }
        // No overlaps: a cue ends no later than the next begins.
        for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start {
            cues[i].end = max(cues[i].start + 0.05, cues[i + 1].start)
        }
        return cues
    }

    private struct Token { var text: String; var start: TimeInterval; var end: TimeInterval }
    private struct Piece { var text: String; var start: TimeInterval; var end: TimeInterval }

    /// Whether text wraps into at most `maxLines` lines within `maxLineLength`.
    private func fits(_ text: String) -> Bool {
        guard Self.width(text) <= maxLineLength * maxLines else { return false }
        let lines = wrap(text)
        return lines.count <= maxLines && lines.allSatisfy { Self.width($0) <= maxLineLength }
    }

    private func split(_ seg: Transcript.Segment) -> [Piece] {
        let text = seg.text.collapsingWhitespace()
        if fits(text) && seg.end - seg.start <= maxCueDuration {
            return [Piece(text: text, start: seg.start, end: seg.end)]
        }
        let tokens = tokens(for: seg, text: text)
        guard !tokens.isEmpty else { return [Piece(text: text, start: seg.start, end: seg.end)] }

        var pieces: [Piece] = []
        var current: [Token] = []
        func flush(_ upTo: Int) {
            let take = Array(current[..<upTo])
            current.removeFirst(upTo)
            guard let first = take.first, let last = take.last else { return }
            pieces.append(Piece(text: Self.join(take.map(\.text)), start: first.start, end: last.end))
        }
        for tok in tokens {
            current.append(tok)
            let duration = (current.last?.end ?? 0) - (current.first?.start ?? 0)
            if current.count > 1, duration > maxCueDuration || !fits(Self.join(current.map(\.text))) {
                // Break after the last clause/sentence punctuation in the first half-or-more, else before this token.
                var cut = current.count - 1
                let minimum = max(1, cut / 2)
                for k in stride(from: current.count - 2, through: minimum - 1, by: -1) {
                    if let ch = current[k].text.trimmed().last, ".!?,;:。！？、，".contains(ch) { cut = k + 1; break }
                }
                flush(cut)
            }
        }
        if !current.isEmpty { flush(current.count) }
        return pieces
    }

    /// Word tokens with times: real word timings when present, otherwise interpolated over the segment.
    private func tokens(for seg: Transcript.Segment, text: String) -> [Token] {
        if let words = seg.words, !words.isEmpty {
            return words.compactMap { w in
                let t = w.text.trimmed()
                return t.isEmpty ? nil : Token(text: t, start: w.start, end: w.end)
            }
        }
        var raw: [String]
        if text.contains(where: TextClass.isNoSpaceScript) {
            // Slices between successive word starts, so punctuation stays attached and nothing is lost.
            var starts: [String.Index] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, r, _, _ in
                starts.append(r.lowerBound)
            }
            if starts.first != text.startIndex { starts.insert(text.startIndex, at: 0) }
            starts.append(text.endIndex)
            raw = zip(starts, starts.dropFirst()).map { String(text[$0..<$1]).trimmed() }
        } else {
            raw = text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        raw.removeAll { $0.isEmpty }
        let total = Double(raw.reduce(0) { $0 + $1.count })
        guard total > 0 else { return [] }
        var tokens: [Token] = []
        var acc = 0.0
        let span = seg.end - seg.start
        for word in raw {
            let s = seg.start + span * acc / total
            acc += Double(word.count)
            tokens.append(Token(text: word, start: s, end: seg.start + span * acc / total))
        }
        return tokens
    }

    /// Wraps cue text into at most `maxLines` balanced lines.
    func wrap(_ text: String) -> [String] {
        let text = text.collapsingWhitespace()
        guard Self.width(text) > maxLineLength, maxLines > 1 else { return [text] }
        let chars = Array(text)
        // Candidate break points: spaces, or between no-space-script characters.
        var candidates: [Int] = []
        for i in 1..<chars.count {
            if chars[i] == " " { candidates.append(i) }
            else if TextClass.isNoSpaceScript(chars[i - 1]) || TextClass.isNoSpaceScript(chars[i]), chars[i - 1] != " " {
                if !"。！？、，」』）".contains(chars[i]) { candidates.append(i) }
            }
        }
        guard !candidates.isEmpty else { return [text] }
        // Two lines: the break that balances widths best, preferring both within the limit.
        let best = candidates.min { a, b in
            func cost(_ i: Int) -> Int {
                let l = Self.width(String(chars[..<i]).trimmed()), r = Self.width(String(chars[i...]).trimmed())
                let over = max(0, l - maxLineLength) + max(0, r - maxLineLength)
                return over * 1000 + abs(l - r)
            }
            return cost(a) < cost(b)
        }!
        let first = String(chars[..<best]).trimmed(), second = String(chars[best...]).trimmed()
        if maxLines > 2, Self.width(second) > maxLineLength {
            var sub = self; sub.maxLines = maxLines - 1
            return [first] + sub.wrap(second)
        }
        return [first, second]
    }

    // MARK: JSON

    public func json(_ t: Transcript) -> String {
        var copy = t
        if !includeWords { copy.segments = copy.segments.map { var s = $0; s.words = nil; return s } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(copy), as: UTF8.self)).map { $0 + "\n" } ?? "{}\n"
    }

    // MARK: Helpers

    /// Display width: CJK and fullwidth characters count as two.
    static func width(_ s: String) -> Int { s.reduce(0) { $0 + (TextClass.isNoSpaceScript($1) && !isThaiLike($1) ? 2 : 1) } }
    private static func isThaiLike(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x0E00...0x109F).contains(v) || (0x1780...0x17FF).contains(v)
    }

    /// Joins word tokens with spaces, except between characters of scripts written without spaces.
    static func join(_ words: [String]) -> String {
        var out = ""
        for w in words where !w.isEmpty {
            if let last = out.last, let first = w.first,
               !(TextClass.isNoSpaceScript(last) && TextClass.isNoSpaceScript(first)) {
                out.append(" ")
            }
            out.append(w)
        }
        return out
    }

    static func clock(_ t: TimeInterval, hours: Bool) -> String {
        let total = Int(max(0, t).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return hours ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func srtTime(_ t: TimeInterval) -> String { stamp(t, separator: ",") }
    static func vttTime(_ t: TimeInterval) -> String { stamp(t, separator: ".") }
    private static func stamp(_ t: TimeInterval, separator: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        let h = ms / 3_600_000, m = (ms % 3_600_000) / 60_000, s = (ms % 60_000) / 1000, f = ms % 1000
        return String(format: "%02d:%02d:%02d", h, m, s) + separator + String(format: "%03d", f)
    }
}
