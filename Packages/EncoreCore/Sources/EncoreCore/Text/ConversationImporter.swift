import Foundation

/// Turns `.txt` / `.pdf` scripts into a `ConversationScript`, and back.
///
/// Understood layouts:
/// - `Name: line` (also `**Name:**`, `Name (whispering): line`, a leading `[00:01:02]` timestamp, and dialogue that
///   starts on the line after `Name:`). Lines without a label continue the current turn (hard wraps are unwrapped,
///   hyphenation undone); after a blank line they start a new line for the same speaker.
/// - Screenplay: a speaker cue in capitals on its own line (`JOHN`, `MARY (V.O.)`, `DR. SMITH (CONT'D)`), dialogue
///   beneath, parentheticals dropped. Scene headings, transitions and action are skipped.
/// - No speaker names at all: each blank-line-separated paragraph is a turn, alternating between two speakers.
/// A `Title: …` line (or a lone first line before any dialogue) becomes the title. A trailing `[pause 1.2s]`
/// on a line becomes that line's `pauseAfter`.
public enum ConversationImporter {
    public enum Layout: String, Sendable, Codable { case labeled, screenplay, paragraphs }

    public struct Result: Sendable {
        public var script: ConversationScript
        public var layout: Layout
        /// Things the user may want to check ("Skipped 12 lines of stage directions.").
        public var notes: [String]
    }

    public enum Failure: LocalizedError {
        case unsupportedType(String)
        case unreadable(URL)
        case empty
        public var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext): "Scripts can be imported from .txt or .pdf files, not .\(ext)."
            case .unreadable(let u): "“\(u.lastPathComponent)” couldn't be read as text."
            case .empty: "No dialogue was found in the script."
            }
        }
    }

    public static func importFile(at url: URL) throws -> Result {
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "pdf":
            text = try PDFTextExtractor.text(from: url)
        case "txt", "text", "md", "markdown", "fountain", "":
            text = try readText(url)
        default:
            throw Failure.unsupportedType(ext)
        }
        var result = parse(text)
        if result.script.lines.isEmpty { throw Failure.empty }
        if result.script.title.isEmpty { result.script.title = url.deletingPathExtension().lastPathComponent }
        return result
    }

    /// UTF-8 (with or without BOM), UTF-16 with BOM, else Windows-1252 (which also covers Latin-1), else Mac Roman.
    /// (The system's encoding sniffer guesses Cyrillic for short Western European text, so it isn't used.)
    static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .macOSRoman) { return s }
        throw Failure.unreadable(url)
    }

    // MARK: Parsing

    public static func parse(_ raw: String) -> Result {
        let lines = normalize(raw)
        var builder = Builder()

        let labels = lines.compactMap(labelMatch)
        var labelCounts: [String: Int] = [:]
        for l in labels { labelCounts[key(l.name), default: 0] += 1 }
        let distinctLabels = labelCounts.keys.filter { !metaLabels.contains($0) }.count
        func accepted(_ m: LabelMatch) -> Bool {
            let k = key(m.name)
            if metaLabels.contains(k) { return true }
            if stopLabels.contains(k) { return false }
            if labelCounts[k, default: 0] >= 2 { return true }
            return m.name.first?.isUppercase ?? false
        }
        let acceptedLabelLines = labels.filter { accepted($0) && !metaLabels.contains(key($0.name)) }.count
        let cueBlocks = countCueBlocks(lines)

        if cueBlocks >= 2, cueBlocks >= acceptedLabelLines {
            parseScreenplay(lines, into: &builder)
            builder.layout = .screenplay
        } else if acceptedLabelLines >= 1, distinctLabels >= 1 {
            parseLabeled(lines, accepted: accepted, into: &builder)
            builder.layout = .labeled
        } else {
            parseParagraphs(lines, into: &builder)
            builder.layout = .paragraphs
        }
        return builder.finish()
    }

    // MARK: Labeled

    private static func parseLabeled(_ lines: [String], accepted: (LabelMatch) -> Bool, into b: inout Builder) {
        var inTurn = false
        var preamble: [String] = []
        var skipped = 0
        for raw in lines {
            let line = stripTimestamp(raw.trimmed())
            if line.isEmpty { inTurn = false; continue }
            if let m = labelMatch(line), accepted(m) {
                if key(m.name) == "title" { b.title = m.text; inTurn = false; continue }
                b.startLine(speaker: m.name, text: m.text)
                inTurn = true
                continue
            }
            if isDirection(line) { skipped += 1; continue }
            if inTurn { b.continueLine(line); continue }
            if b.lines.isEmpty { preamble.append(line); continue }
            // A new paragraph without a label: the last speaker keeps talking.
            b.startLine(speaker: b.lastSpeakerName!, text: line)
            inTurn = true
        }
        if b.title.isEmpty, preamble.count == 1 { b.title = cleanTitle(preamble[0]) }
        else if !preamble.isEmpty { b.notes.append("Skipped \(preamble.count) line\(preamble.count == 1 ? "" : "s") before the first speaker.") }
        if skipped > 0 { b.notes.append("Skipped \(skipped) stage direction\(skipped == 1 ? "" : "s").") }
    }

    // MARK: Screenplay

    private static func countCueBlocks(_ lines: [String]) -> Int {
        var n = 0
        for (i, l) in lines.enumerated() where cueName(l) != nil {
            if i + 1 < lines.count, !lines[i + 1].trimmed().isEmpty, cueName(lines[i + 1]) == nil { n += 1 }
        }
        return n
    }

    private static func parseScreenplay(_ lines: [String], into b: inout Builder) {
        var i = 0
        var skippedAction = 0
        var previousEndedWithMore = false
        var seenDialogue = false
        var preamble: [String] = []
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmed()
            if t.isEmpty || isScreenplayArtifact(t) { i += 1; continue }
            guard let cue = cueName(line), i + 1 < lines.count, !lines[i + 1].trimmed().isEmpty else {
                if !seenDialogue { preamble.append(t) } else if !isSceneHeadingOrTransition(t) { skippedAction += 1 }
                i += 1; continue
            }
            // Dialogue block.
            let cueIndent = indent(of: line)
            var dialogueIndent: Int?
            var parts: [String] = []
            var inParenthetical = false
            var endedWithMore = false
            i += 1
            while i < lines.count {
                let l = lines[i], lt = l.trimmed()
                if lt.isEmpty { break }
                if cueName(l) != nil, !inParenthetical, lt == lt.uppercased(), !parts.isEmpty { break }
                if lt.uppercased() == "(MORE)" { endedWithMore = true; i += 1; continue }
                if isScreenplayArtifact(lt) { i += 1; continue }
                // In indented layouts (PDF), a line back at the action margin ends the block.
                let ind = indent(of: l)
                if let d = dialogueIndent, cueIndent > 0, ind + 3 < d, !inParenthetical { break }
                if lt.hasPrefix("(") || inParenthetical {
                    inParenthetical = !lt.hasSuffix(")")
                    i += 1; continue
                }
                if dialogueIndent == nil { dialogueIndent = ind }
                parts.append(lt)
                i += 1
            }
            guard !parts.isEmpty else { continue }
            seenDialogue = true
            let text = parts.reduce("") { joinWrapped($0, $1) }
            if previousEndedWithMore, cue.continued, b.lastSpeakerName.map(key) == key(cue.name) {
                b.continueLine(text)
            } else {
                b.startLine(speaker: cue.name, text: text)
            }
            previousEndedWithMore = endedWithMore
        }
        if b.title.isEmpty, let first = preamble.first, preamble.count <= 3, !isSceneHeadingOrTransition(first) {
            b.title = cleanTitle(first)
        }
        if skippedAction > 0 {
            b.notes.append("Skipped \(skippedAction) line\(skippedAction == 1 ? "" : "s") of action and scene directions.")
        }
    }

    struct Cue { var name: String; var continued: Bool }

    /// A screenplay character cue: short, all capitals, optionally with (V.O.), (O.S.), (CONT'D)…
    static func cueName(_ line: String) -> Cue? {
        var t = line.trimmed()
        guard !t.isEmpty, t.count <= 50 else { return nil }
        if t.hasPrefix("@") { t.removeFirst() }                 // Fountain forced cue
        if t.hasSuffix("^") { t.removeLast(); t = t.trimmed() } // Fountain dual dialogue
        var continued = false
        while let open = t.lastIndex(of: "("), t.hasSuffix(")") {
            let ext = t[t.index(after: open)..<t.index(before: t.endIndex)].uppercased()
            if ext.contains("CONT") { continued = true }
            t = String(t[..<open]).trimmed()
        }
        guard !t.isEmpty, t.count <= 38, t.contains(where: \.isLetter) else { return nil }
        guard t == t.uppercased(), t.contains(where: { $0.isLetter && $0.isUppercase }) else { return nil }
        guard t.split(separator: " ").count <= 4 else { return nil }
        guard !isSceneHeadingOrTransition(t), !isScreenplayArtifact(t) else { return nil }
        guard let last = t.last, !"!?:;,".contains(last) else { return nil }
        guard t.allSatisfy({ $0.isLetter || $0.isNumber || " .'’-&#".contains($0) }) else { return nil }
        return Cue(name: displayName(t), continued: continued)
    }

    static func isSceneHeadingOrTransition(_ t: String) -> Bool {
        let u = t.uppercased()
        let headings = ["INT.", "EXT.", "INT ", "EXT ", "INT/EXT", "I/E", "EST.", "EXT/INT"]
        if headings.contains(where: u.hasPrefix) { return true }
        if u.hasSuffix(" TO:") || u.hasSuffix(" IN:") || u.hasSuffix(" OUT.") || u.hasSuffix(" OUT:") { return true }
        return ["FADE IN", "FADE OUT", "FADE TO BLACK", "THE END", "END", "CUT TO", "BLACK.", "TITLE CARD", "INTERCUT",
                "MONTAGE", "BACK TO SCENE", "LATER", "CONTINUOUS"].contains { u == $0 || u == $0 + "." || u == $0 + ":" }
    }

    static func isScreenplayArtifact(_ t: String) -> Bool {
        let u = t.uppercased()
        return u == "(MORE)" || u == "CONTINUED:" || u == "(CONTINUED)" || u == "CONTINUED" || u.hasPrefix("CONTINUED:")
    }

    // MARK: Paragraphs

    private static func parseParagraphs(_ lines: [String], into b: inout Builder) {
        var paragraph: [String] = []
        var turn = 0
        func flush() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.reduce("") { joinWrapped($0, $1) }
            paragraph = []
            if isDirection(text) { return }
            b.startLine(speaker: "Speaker \(turn % 2 + 1)", text: text)
            turn += 1
        }
        for l in lines {
            let t = l.trimmed()
            if t.isEmpty { flush() } else { paragraph.append(t) }
        }
        flush()
        if turn > 1 { b.notes.append("No speaker names were found, so paragraphs alternate between two speakers.") }
    }

    // MARK: Labels

    struct LabelMatch { var name: String; var text: String }

    private static let labelRegex = try! NSRegularExpression(pattern:
        #"^(?:\*\*|__)?([\p{L}][\p{L}\p{M}\p{N} .'’&_\-]{0,39}?)\s*(?:\*\*|__)?\s*(?:\(([^)]{0,40})\))?\s*(?:\*\*|__)?\s*[:：](?:\*\*|__)?(?:\s+(.*))?$"#)

    static func labelMatch(_ rawLine: String) -> LabelMatch? {
        let line = stripTimestamp(rawLine.trimmed())
        let ns = line as NSString
        guard let m = labelRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 1)).trimmed()
        guard !name.isEmpty, name.split(separator: " ").count <= 4 else { return nil }
        let text = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3)).trimmed()
        let display = name == name.uppercased() && name.contains(where: \.isLetter) ? displayName(name) : name
        return LabelMatch(name: display, text: text)
    }

    /// Labels that are about the document, not a speaker.
    static let metaLabels: Set<String> = ["title"]
    /// Words that look like labels but almost never name a speaker.
    static let stopLabels: Set<String> = ["note", "notes", "warning", "subject", "date", "time", "re", "fwd", "http",
                                          "https", "scene", "setting", "chapter", "act", "summary", "ps", "nb", "cast",
                                          "characters", "location", "author", "written by", "draft", "page", "tip"]

    // MARK: Helpers

    static func normalize(_ raw: String) -> [String] {
        var s = raw
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\u{0C}", with: "\n\n").replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: "    ")
        return s.components(separatedBy: "\n").map { line in
            var l = line
            while let last = l.last, last.isWhitespace { l.removeLast() }
            return l
        }
    }

    private static let timestampRegex = try! NSRegularExpression(pattern: #"^[\[(]?\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d+)?[\])]?\s+"#)
    static func stripTimestamp(_ line: String) -> String {
        let ns = line as NSString
        guard let m = timestampRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        return ns.substring(from: m.range.upperBound)
    }

    static func indent(of line: String) -> Int { line.prefix { $0 == " " }.count }

    /// Whole-line stage directions: `(They leave.)`, `[Music]`, `*sighs*`.
    static func isDirection(_ t: String) -> Bool {
        // A lone Encore pause tag is not a direction.
        if let tok = TagLexer.scan(t).first, tok.range == t.startIndex..<t.endIndex,
           case .pause = ScriptParser.classify(tok) { return false }
        guard t.count >= 2, let f = t.first, let l = t.last else { return false }
        return (f == "(" && l == ")") || (f == "[" && l == "]") || (f == "*" && l == "*") || (f == "_" && l == "_")
    }

    /// Joins hard-wrapped lines: undoes end-of-line hyphenation ("exam-" + "ple"), otherwise adds a space.
    static func joinWrapped(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let chars = Array(a)
        if chars.count >= 2, chars.last == "-", chars[chars.count - 2].isLetter, let f = b.first, f.isLowercase {
            return String(chars.dropLast()) + b
        }
        if let last = a.last, let first = b.first, TextClass.isNoSpaceScript(last) && TextClass.isNoSpaceScript(first) {
            return a + b
        }
        return a + " " + b
    }

    static func key(_ name: String) -> String { ScriptVoiceDirectory.key(name) }

    /// "MARY JANE" → "Mary Jane"; short all-caps words ("DJ", "MC") stay as they are.
    static func displayName(_ caps: String) -> String {
        caps.split(separator: " ", omittingEmptySubsequences: true).map { word -> String in
            let letters = word.filter(\.isLetter).count
            guard letters >= 3 else { return String(word) }
            return word.lowercased().capitalized(with: nil)
        }.joined(separator: " ")
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s.trimmed()
        while t.hasPrefix("#") { t.removeFirst() }
        if t.hasPrefix("Title:") { t = String(t.dropFirst(6)) }
        return t.trimmed()
    }

    // MARK: Builder

    struct Builder {
        var title = ""
        var speakers: [ConversationScript.Speaker] = []
        var lines: [ConversationScript.Line] = []
        var notes: [String] = []
        var layout: Layout = .labeled
        var lastSpeakerName: String? {
            guard let last = lines.last else { return nil }
            return speakers.first { $0.id == last.speakerID }?.name
        }

        mutating func startLine(speaker name: String, text: String) {
            let k = ConversationImporter.key(name)
            let speaker: ConversationScript.Speaker
            if let s = speakers.first(where: { ConversationImporter.key($0.name) == k }) { speaker = s }
            else { speaker = .init(name: name); speakers.append(speaker) }
            lines.append(.init(speakerID: speaker.id, text: text))
        }

        mutating func continueLine(_ text: String) {
            guard !lines.isEmpty else { return }
            lines[lines.count - 1].text = ConversationImporter.joinWrapped(lines[lines.count - 1].text, text)
        }

        func finish() -> Result {
            var script = ConversationScript()
            script.title = title
            script.speakers = speakers
            script.lines = lines.compactMap { line in
                var l = line
                l.text = l.text.collapsingWhitespace()
                // A trailing pause tag sets the pause after this line.
                let tokens = TagLexer.scan(l.text)
                if let last = tokens.last, last.range.upperBound == l.text.endIndex,
                   case .pause(let p) = ScriptParser.classify(last) {
                    l.pauseAfter = p.seconds
                    l.text = String(l.text[..<last.range.lowerBound]).trimmed()
                }
                return l.text.isEmpty && l.pauseAfter == nil ? nil : l
            }
            // Drop speakers whose every line vanished.
            let used = Set(script.lines.map(\.speakerID))
            script.speakers.removeAll { !used.contains($0.id) }
            return Result(script: script, layout: layout, notes: notes)
        }
    }

    // MARK: Serialising

    /// `Title: …`, a blank line, then one `Name: text` line per turn. `pauseAfter` is written as a trailing
    /// `[pause 1.2s]`. `parse` reads this back to the same speakers, lines and pauses.
    public static func text(for script: ConversationScript) -> String {
        var out: [String] = []
        if !script.title.trimmed().isEmpty { out.append("Title: \(script.title.collapsingWhitespace())"); out.append("") }
        let names = Dictionary(uniqueKeysWithValues: script.speakers.map { ($0.id, $0.name) })
        for line in script.lines {
            var name = (names[line.speakerID] ?? "Speaker").collapsingWhitespace().replacingOccurrences(of: ":", with: " -")
            if name.isEmpty { name = "Speaker" }
            var text = line.text.collapsingWhitespace()
            if let p = line.pauseAfter {
                let ms = Int((p * 1000).rounded())
                text += (text.isEmpty ? "" : " ") + (ms % 1000 == 0 ? "[pause \(ms / 1000)s]" : "[pause \(ms)ms]")
            }
            out.append("\(name): \(text)")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
