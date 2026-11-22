import Foundation

// Script markup: Encore's own tags (pauses, voice switches) and the model's native expressive tags.
//
//   Pauses   [pause 0.8s]  [pause 500ms]  [pause 2]  [pause]  <break time="1s"/>  <break strength="strong"/>
//   Voices   [voice: Name]  [voice = Name]  [voice: default] (back to the request's voice)
//   Native   whatever the manifest's `expressiveTags` list, e.g. [laugh] <sigh>; passed to the model untouched.
//
// Encore inserts real silence for pauses, so they work with every model.

// MARK: - Tag vocabulary

/// The model-native tags a script may contain. Built from `ModelManifest.expressiveTags`.
///
/// A manifest tag containing `*` describes a family: `[S*]` matches `[S1]`, `[S2]`…;
/// `<emotion=*>` matches `<emotion=happy>`. An angle tag `<x>` also admits its closing form `</x>`.
/// Matching ignores case and runs of whitespace; the text itself is never changed.
public struct TagVocabulary: Sendable, Hashable {
    private var literals: Set<String> = []
    private var families: [Family] = []

    private struct Family: Sendable, Hashable { var prefix: String; var suffix: String }

    public static let none = TagVocabulary(tags: [])

    public init(tags: [String]) {
        for raw in tags {
            let tag = Self.normalize(raw)
            guard !tag.isEmpty else { continue }
            if let star = tag.firstIndex(of: "*") {
                let suffix = String(tag[tag.index(after: star)...]).replacingOccurrences(of: "*", with: "")
                families.append(Family(prefix: String(tag[..<star]), suffix: suffix))
            } else {
                literals.insert(tag)
                // <whisper> or <whisper ...> admits </whisper>.
                if tag.hasPrefix("<"), !tag.hasPrefix("</") {
                    let name = tag.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                    if !name.isEmpty { literals.insert("</\(name)>") }
                }
            }
        }
    }

    public init(expressiveTags: [ExpressiveTag]) { self.init(tags: expressiveTags.map(\.tag)) }
    public init(manifest: ModelManifest) { self.init(expressiveTags: manifest.expressiveTags) }

    public var isEmpty: Bool { literals.isEmpty && families.isEmpty }

    /// True when `tagText` (including its brackets) is one of the model's own tags.
    public func contains(_ tagText: some StringProtocol) -> Bool {
        let t = Self.normalize(String(tagText))
        if literals.contains(t) { return true }
        return families.contains { f in
            t.count > f.prefix.count + f.suffix.count && t.hasPrefix(f.prefix) && t.hasSuffix(f.suffix)
        }
    }

    static func normalize(_ s: String) -> String { s.lowercased().collapsingWhitespace() }
}

// MARK: - Tag lexing

/// A bracketed span that looks like a tag: `[…]` on one line with no nested `[`, or `<…>` starting
/// with a letter or `/`. Lexing knows nothing about meaning; it is what the chunker and the
/// pronunciation matcher protect from being split or rewritten.
struct TagToken: Hashable {
    enum Delimiter: Hashable { case square, angle }
    var range: Range<String.Index>
    var delimiter: Delimiter
    /// Text between the delimiters.
    var inner: Substring
}

enum TagLexer {
    static let maxSquareLength = 100
    static let maxAngleLength = 200

    static func scan(_ text: String, in range: Range<String.Index>? = nil) -> [TagToken] {
        let range = range ?? text.startIndex..<text.endIndex
        var tokens: [TagToken] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let c = text[i]
            if c == "[" || c == "<" {
                let square = c == "["
                let open = square ? Character("[") : Character("<")
                let close = square ? Character("]") : Character(">")
                let limit = square ? maxSquareLength : maxAngleLength
                var j = text.index(after: i)
                if !square {
                    guard j < end, text[j].isLetter || text[j] == "/" else { i = j; continue }
                }
                var count = 0
                var closed: String.Index?
                while j < end, count <= limit {
                    let d = text[j]
                    if d == close { closed = j; break }
                    if d == open || d.isNewline { break }
                    j = text.index(after: j); count += 1
                }
                if let closed {
                    let inner = text[text.index(after: i)..<closed]
                    if !inner.trimmed().isEmpty {
                        let after = text.index(after: closed)
                        tokens.append(TagToken(range: i..<after, delimiter: square ? .square : .angle, inner: inner))
                        i = after
                        continue
                    }
                }
            }
            i = text.index(after: i)
        }
        return tokens
    }
}

// MARK: - Parsed script

public enum ScriptTagKind: String, Sendable, Hashable, Codable {
    /// Encore pause: real silence.
    case pause
    /// Encore voice switch.
    case voice
    /// A tag the model itself understands; passed through.
    case expressive
    /// Looks like a tag but isn't one Encore or this model knows. It stays in the text and the model will see it.
    case unrecognized
}

/// A recognized tag in the script, for highlighting.
public struct ScriptTag: Sendable, Hashable {
    public var kind: ScriptTagKind
    public var range: Range<String.Index>
    /// The same range in UTF-16 units, for NSTextView/NSAttributedString.
    public var utf16Range: NSRange
    public var text: String
}

public struct ScriptIssue: Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable, Codable { case info, warning, error }
    public var severity: Severity
    public var message: String
    public var range: Range<String.Index>
    public var utf16Range: NSRange
}

public struct ScriptSegment: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        /// Text for the model, as written (expressive tags included, Encore tags removed), trimmed.
        case speech(String)
        /// Silence, seconds. Adjacent pause tags are merged.
        case pause(TimeInterval)
    }
    public var content: Content
    /// The voice for a speech segment. `nil` means the request's own voice (no `[voice:]` tag in effect).
    public var voice: VoiceSelection?
    /// Where this segment came from in the script.
    public var range: Range<String.Index>
    public var utf16Range: NSRange

    public var text: String? { if case .speech(let t) = content { t } else { nil } }
    public var pauseSeconds: TimeInterval? { if case .pause(let s) = content { s } else { nil } }
}

public struct ParsedScript: Sendable {
    public var segments: [ScriptSegment] = []
    /// Every tag found, in order — Encore's, the model's, and unrecognized ones.
    public var tags: [ScriptTag] = []
    public var issues: [ScriptIssue] = []
    /// `[voice:]` names that matched nothing, in order of first appearance.
    public var unknownVoiceNames: [String] = []

    public var hasErrors: Bool { issues.contains { $0.severity == .error } }
    public var speechText: String { segments.compactMap(\.text).joined(separator: " ") }
}

// MARK: - Voice names

/// Names a `[voice: …]` tag can refer to: library voices first, then the model's preset voices
/// (by display name or id). Matching ignores case, diacritics and surrounding quotes.
public struct ScriptVoiceDirectory: Sendable {
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var selection: VoiceSelection
        public init(name: String, selection: VoiceSelection) { self.name = name; self.selection = selection }
    }
    public var entries: [Entry]

    public static let empty = ScriptVoiceDirectory(entries: [])

    public init(entries: [Entry]) { self.entries = entries }

    public init(library: [Voice], presets: [PresetVoice] = []) {
        var e = library.map { Entry(name: $0.name, selection: .library($0.id)) }
        for p in presets {
            e.append(Entry(name: p.name, selection: .preset(p.id)))
            if p.id != p.name { e.append(Entry(name: p.id, selection: .preset(p.id))) }
        }
        entries = e
    }

    public func resolve(_ name: String) -> VoiceSelection? {
        let key = Self.key(name)
        guard !key.isEmpty else { return nil }
        return entries.first { Self.key($0.name) == key }?.selection
    }

    static func key(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’")))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .collapsingWhitespace()
    }
}

// MARK: - Parser

/// Turns a script into speech and pause segments, plus what an editor needs (tag ranges, issues).
public struct ScriptParser: Sendable {
    public var vocabulary: TagVocabulary
    public var voices: ScriptVoiceDirectory

    /// What a bare `[pause]` or `<break/>` means, seconds.
    public static let defaultPauseSeconds: TimeInterval = 0.5
    /// Pauses are clamped to this, seconds.
    public static let maximumPauseSeconds: TimeInterval = 30

    public init(vocabulary: TagVocabulary = .none, voices: ScriptVoiceDirectory = .empty) {
        self.vocabulary = vocabulary; self.voices = voices
    }

    public func parse(_ text: String) -> ParsedScript {
        var result = ParsedScript()
        var currentVoice: VoiceSelection?
        var cursor = text.startIndex

        func ns(_ r: Range<String.Index>) -> NSRange { NSRange(r, in: text) }
        func issue(_ severity: ScriptIssue.Severity, _ message: String, _ r: Range<String.Index>) {
            result.issues.append(ScriptIssue(severity: severity, message: message, range: r, utf16Range: ns(r)))
        }
        func flushSpeech(upTo end: String.Index) {
            let r = text.trimmedRange(cursor..<end)
            guard !r.isEmpty else { return }
            result.segments.append(ScriptSegment(content: .speech(String(text[r])), voice: currentVoice,
                                                 range: r, utf16Range: ns(r)))
        }
        func addPause(_ seconds: TimeInterval, _ r: Range<String.Index>) {
            if let last = result.segments.last, case .pause(let s) = last.content, last.range.upperBound <= r.lowerBound,
               text[last.range.upperBound..<r.lowerBound].allSatisfy(\.isWhitespace) {
                let merged = last.range.lowerBound..<r.upperBound
                result.segments[result.segments.count - 1] = ScriptSegment(
                    content: .pause(min(s + seconds, Self.maximumPauseSeconds)), voice: nil, range: merged, utf16Range: ns(merged))
            } else {
                result.segments.append(ScriptSegment(content: .pause(seconds), voice: nil, range: r, utf16Range: ns(r)))
            }
        }

        for token in TagLexer.scan(text) {
            let r = token.range
            let tagText = String(text[r])
            func tag(_ kind: ScriptTagKind) {
                result.tags.append(ScriptTag(kind: kind, range: r, utf16Range: ns(r), text: tagText))
            }

            // The model's own tags win, so a model that natively understands `[pause]` keeps it.
            if vocabulary.contains(tagText) { tag(.expressive); continue }

            switch Self.classify(token) {
            case .pause(let parsed):
                tag(.pause)
                flushSpeech(upTo: r.lowerBound)
                var seconds = parsed.seconds
                if let note = parsed.note { issue(.info, note, r) }
                if seconds > Self.maximumPauseSeconds {
                    issue(.warning, "Pauses are limited to \(Self.format(Self.maximumPauseSeconds)).", r)
                    seconds = Self.maximumPauseSeconds
                }
                addPause(seconds, r)
                cursor = r.upperBound
            case .malformedPause(let message):
                tag(.pause)
                issue(.error, message, r)
                flushSpeech(upTo: r.lowerBound)
                cursor = r.upperBound
            case .voice(let name):
                tag(.voice)
                flushSpeech(upTo: r.lowerBound)
                cursor = r.upperBound
                if let selection = voices.resolve(name) {
                    currentVoice = selection
                } else if ["default", "automatic", "none"].contains(ScriptVoiceDirectory.key(name)) {
                    currentVoice = nil
                } else if name.isEmpty {
                    issue(.error, "The voice tag needs a name, like [voice: Ava].", r)
                } else {
                    issue(.warning, "No voice named “\(name)”. The previous voice continues.", r)
                    if !result.unknownVoiceNames.contains(where: { ScriptVoiceDirectory.key($0) == ScriptVoiceDirectory.key(name) }) {
                        result.unknownVoiceNames.append(name)
                    }
                }
            case .other(let looksIntended):
                guard looksIntended else { continue }
                tag(.unrecognized)
                if vocabulary.isEmpty {
                    issue(.warning, "This model has no sound tags; \(tagText) may be read aloud.", r)
                } else {
                    issue(.warning, "\(tagText) isn't one of this model's tags; it may be read aloud.", r)
                }
            }
        }
        flushSpeech(upTo: text.endIndex)
        return result
    }

    // MARK: Classification

    enum Classified: Equatable {
        case pause(ParsedPause)
        case malformedPause(String)
        case voice(String)
        /// Not Encore's. `looksIntended` when it reads like a tag someone meant (`[giggle]`), not `[1]` or `a<b>`.
        case other(looksIntended: Bool)
    }

    struct ParsedPause: Equatable { var seconds: TimeInterval; var note: String? }

    static func classify(_ token: TagToken) -> Classified {
        let inner = token.inner.trimmed()
        let lower = inner.lowercased()
        switch token.delimiter {
        case .square:
            if let rest = keywordRest(lower, "pause") {
                return parsePauseAmount(rest, bareNumbersAllowed: true)
            }
            if let rest = keywordRest(inner, "voice", caseInsensitive: true) {
                var name = rest
                if let f = name.first, f == ":" || f == "=" { name.removeFirst() }
                return .voice(name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’"))))
            }
            let intended = inner.first?.isLetter == true && inner.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" || $0 == "'" || $0 == "’" || $0 == ":"
            }
            return .other(looksIntended: intended)
        case .angle:
            if let rest = keywordRest(lower, "break") {
                var attrs = rest.trimmed()
                if attrs.hasSuffix("/") { attrs.removeLast() }
                return parseBreakAttributes(attrs)
            }
            return .other(looksIntended: true)
        }
    }

    /// If `s` starts with `keyword` followed by end, whitespace, `:` or `=`, the remainder (trimmed).
    private static func keywordRest(_ s: String, _ keyword: String, caseInsensitive: Bool = false) -> String? {
        let probe = caseInsensitive ? s.lowercased() : s
        guard probe.hasPrefix(keyword) else { return nil }
        let rest = s.dropFirst(keyword.count)
        if let f = rest.first, !(f.isWhitespace || f == ":" || f == "=" || f == "/") { return nil }
        return rest.trimmed()
    }

    static func parsePauseAmount(_ raw: String, bareNumbersAllowed: Bool) -> Classified {
        var s = raw.trimmed()
        if let f = s.first, f == ":" || f == "=" { s = String(s.dropFirst()).trimmed() }
        if s.isEmpty { return .pause(ParsedPause(seconds: defaultPauseSeconds, note: nil)) }
        // Number: digits with an optional decimal point or comma.
        var numberText = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isASCII, s[idx].isNumber || s[idx] == "." || s[idx] == "," {
            numberText.append(s[idx] == "," ? "." : s[idx]); idx = s.index(after: idx)
        }
        let unit = s[idx...].trimmed()
        guard let value = Double(numberText), value.isFinite, value >= 0 else {
            return .malformedPause("Couldn't read the pause length. Try [pause 1s] or [pause 500ms].")
        }
        switch unit {
        case "s", "sec", "secs", "second", "seconds":
            return .pause(ParsedPause(seconds: value, note: nil))
        case "ms", "msec", "msecs", "millisecond", "milliseconds":
            return .pause(ParsedPause(seconds: value / 1000, note: nil))
        case "" where bareNumbersAllowed:
            // "[pause 500]" almost certainly means milliseconds.
            if value >= 100 {
                return .pause(ParsedPause(seconds: value / 1000, note: "Read as \(format(value / 1000)) (milliseconds)."))
            }
            return .pause(ParsedPause(seconds: value, note: nil))
        case "":
            return .pause(ParsedPause(seconds: value, note: nil))
        default:
            return .malformedPause("Unknown pause unit “\(unit)”. Use s or ms.")
        }
    }

    /// SSML `<break time="1s"/>` / `<break strength="strong"/>`.
    static func parseBreakAttributes(_ attrs: String) -> Classified {
        if attrs.isEmpty { return .pause(ParsedPause(seconds: defaultPauseSeconds, note: nil)) }
        let values = attributes(attrs)
        if let time = values["time"] {
            return parsePauseAmount(time, bareNumbersAllowed: false)
        }
        if let strength = values["strength"] {
            let map: [String: TimeInterval] = ["none": 0, "x-weak": 0.1, "weak": 0.25, "medium": 0.5,
                                               "strong": 0.75, "x-strong": 1.25]
            if let s = map[strength.lowercased()] { return .pause(ParsedPause(seconds: s, note: nil)) }
            return .malformedPause("Unknown break strength “\(strength)”.")
        }
        return .malformedPause("A break needs time=\"…\" or strength=\"…\".")
    }

    private static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"([A-Za-z_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                out[key] = ns.substring(with: m.range(at: g)); break
            }
        }
        return out
    }

    static func format(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        let s = (seconds * 100).rounded() / 100
        return s == s.rounded() ? "\(Int(s)) s" : "\(s) s"
    }
}
