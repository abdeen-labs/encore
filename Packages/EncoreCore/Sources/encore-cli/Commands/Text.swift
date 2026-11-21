import EncoreCore
import EncoreMLX
import Foundation

// encore-cli text chunk <file|-> [--max N] [--model ID]
// encore-cli text parse <file|-> [--model ID] [--voice NAME]… [--pronunciations list.csv|json] [--max N]
// encore-cli text script-import <file.txt|file.pdf> [--json] [--raw]
// encore-cli text format <transcript.json> [--as text|timestampedText|srt|vtt|json]

func runTextCommand(_ args: [String]) async throws {
    guard let sub = args.first else { return textUsage() }
    var options = TextOptions(Array(args.dropFirst()))
    switch sub {
    case "chunk": try textChunk(&options)
    case "parse": try textParse(&options)
    case "script-import": try textScriptImport(&options)
    case "format": try textFormat(&options)
    default: textUsage()
    }
}

private func textUsage() {
    print("""
    usage: encore-cli text chunk <file|-> [--max N] [--model ID]
           encore-cli text parse <file|-> [--model ID] [--voice NAME]… [--pronunciations FILE] [--max N]
           encore-cli text script-import <file.txt|file.pdf> [--json] [--raw]
           encore-cli text format <transcript.json> [--as \(TranscriptFormat.allCases.map(\.rawValue).joined(separator: "|"))]
    """)
}

private struct TextOptions {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if ["json", "raw"].contains(key) { flags.insert(key) }
                else if i + 1 < args.count { values[key, default: []].append(args[i + 1]); i += 1 }
            } else { positional.append(a) }
            i += 1
        }
    }
    func value(_ k: String) -> String? { values[k]?.last }
    func input() throws -> (String, String) {
        guard let path = positional.first else { throw CLIError("missing input file") }
        if path == "-" {
            return (String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self), "stdin")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return (try String(contentsOf: url, encoding: .utf8), url.lastPathComponent)
    }
}

private struct CLIError: LocalizedError {
    var errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

private func manifest(_ options: TextOptions) throws -> ModelManifest? {
    guard let id = options.value("model") else { return nil }
    guard let m = ModelCatalog.bundled().catalog.model(id) else { throw CLIError("no bundled model “\(id)”") }
    return m
}

private func show(_ s: String) -> String {
    s.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
}

private func offset(_ text: String, _ r: Range<String.Index>) -> String {
    let ns = NSRange(r, in: text)
    return "\(ns.location)..<\(ns.location + ns.length)"
}

private func textChunk(_ options: inout TextOptions) throws {
    let (text, _) = try options.input()
    let model = try manifest(options)
    let max = options.value("max").flatMap(Int.init) ?? model?.maxChunkCharacters ?? 300
    let chunks = TextChunker(maxCharacters: max).chunks(of: text)
    print("\(chunks.count) chunk(s), limit \(max) characters")
    for (i, c) in chunks.enumerated() {
        print(String(format: "%3d  %4d chars  %-9@  utf16 %@", i + 1, c.text.count, c.boundary.rawValue, offset(text, c.range)))
        print("     \(show(c.text))")
    }
}

private func textParse(_ options: inout TextOptions) throws {
    let (text, _) = try options.input()
    let model = try manifest(options)
    var entries = (options.values["voice"] ?? []).map { ScriptVoiceDirectory.Entry(name: $0, selection: .preset($0)) }
    if let m = model { entries += ScriptVoiceDirectory(library: [], presets: m.presetVoices).entries }
    var pronunciations: [PronunciationEntry] = []
    if let path = options.value("pronunciations") {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        pronunciations = url.pathExtension.lowercased() == "json"
            ? try JSONDecoder().decode([PronunciationEntry].self, from: Data(contentsOf: url))
            : try PronunciationStore.parseCSV(String(contentsOf: url, encoding: .utf8))
    }
    let parser = ScriptParser(vocabulary: model.map(TagVocabulary.init(manifest:)) ?? .none, voices: ScriptVoiceDirectory(entries: entries))
    let max = options.value("max").flatMap(Int.init) ?? model?.maxChunkCharacters
    let plan = ScriptPlanner(parser: parser, maxChunkCharacters: max, pronunciations: pronunciations).plan(text)

    print("Tags:")
    for t in plan.parsed.tags { print("  \(t.kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(offset(text, t.range))  \(t.text)") }
    if !plan.issues.isEmpty {
        print("Issues:")
        for i in plan.issues { print("  \(i.severity.rawValue): \(i.message)  [\(offset(text, i.range))]") }
    }
    if !plan.parsed.unknownVoiceNames.isEmpty { print("Unknown voices: \(plan.parsed.unknownVoiceNames.joined(separator: ", "))") }
    print("Plan:")
    for item in plan.items {
        switch item {
        case .pause(let s, _): print("  pause \(s) s")
        case .speech(let c):
            let voice = c.voice.map { "\($0)" } ?? "request voice"
            print("  speech [\(voice)] gap \(c.gapAfter) s  \(c.boundary.rawValue)")
            print("    \(show(c.text))")
        }
    }
}

private func textScriptImport(_ options: inout TextOptions) throws {
    guard let path = options.positional.first else { throw CLIError("missing script file") }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    if options.flags.contains("raw"), url.pathExtension.lowercased() == "pdf" {
        print(try PDFTextExtractor.text(from: url))
        return
    }
    let result = try ConversationImporter.importFile(at: url)
    if options.flags.contains("json") {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try e.encode(result.script), as: UTF8.self))
        return
    }
    print("Layout: \(result.layout.rawValue)  speakers: \(result.script.speakers.map(\.name).joined(separator: ", "))  lines: \(result.script.lines.count)")
    for n in result.notes { print("Note: \(n)") }
    print("")
    print(ConversationImporter.text(for: result.script), terminator: "")
}

private func textFormat(_ options: inout TextOptions) throws {
    guard let path = options.positional.first else { throw CLIError("missing transcript JSON") }
    let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    let transcript: Transcript
    if let t = try? JSONDecoder().decode(Transcript.self, from: data) { transcript = t }
    else if let r = try? JSONDecoder().decode(TranscriptionRecord.self, from: data) { transcript = r.transcript }
    else { throw CLIError("not a Transcript or TranscriptionRecord JSON") }
    let name = options.value("as") ?? "srt"
    guard let format = TranscriptFormat(rawValue: name) else { throw CLIError("unknown format “\(name)”") }
    print(TranscriptFormatter().string(transcript, as: format), terminator: "")
}
