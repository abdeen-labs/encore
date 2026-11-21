import Foundation
import Observation
import Synchronization

/// The user's pronunciation list, in the user's order. Stored as `<directory>/pronunciations.json`.
/// Threading: see StoreSupport.swift. `enabledEntries()` is callable from any isolation.
@MainActor @Observable
public final class PronunciationStore {
    public private(set) var entries: [PronunciationEntry] = []
    public private(set) var loadError: String?

    @ObservationIgnored public nonisolated let fileURL: URL
    @ObservationIgnored private nonisolated let snapshot = Mutex<[PronunciationEntry]>([])

    public init(directory: URL = EncorePaths.applicationSupport) {
        fileURL = directory.appendingPathComponent("pronunciations.json")
        do {
            entries = try StoreFiles.read([PronunciationEntry].self, from: fileURL) ?? []
        } catch {
            loadError = "The pronunciation list couldn't be read: \(error.localizedDescription)"
            StoreFiles.quarantine(fileURL)
        }
        snapshot.withLock { $0 = entries }
    }

    /// Enabled entries, for `PronunciationApplier` / `ScriptPlanner`.
    public nonisolated func enabledEntries() -> [PronunciationEntry] { snapshot.withLock { $0.filter(\.enabled) } }

    // MARK: Editing

    /// Adds an entry, or replaces the one with the same id.
    public func save(_ entry: PronunciationEntry) throws {
        var all = entries
        if let i = all.firstIndex(where: { $0.id == entry.id }) { all[i] = entry } else { all.append(entry) }
        try commit(all)
    }

    public func setEnabled(_ enabled: Bool, for id: UUID) throws {
        guard var e = entries.first(where: { $0.id == id }) else { throw StoreError.notFound("The pronunciation") }
        e.enabled = enabled
        try save(e)
    }

    public func delete(_ ids: Set<UUID>) throws { try commit(entries.filter { !ids.contains($0.id) }) }

    /// Moves the entries at `offsets` so they sit before `destination` (List `onMove` semantics).
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        var all = entries
        let moving = offsets.sorted().map { all[$0] }
        let before = offsets.filter { $0 < destination }.count
        for i in offsets.sorted(by: >) { all.remove(at: i) }
        all.insert(contentsOf: moving, at: min(all.count, destination - before))
        try commit(all)
    }

    public func replaceAll(_ newEntries: [PronunciationEntry]) throws { try commit(newEntries) }

    private func commit(_ all: [PronunciationEntry]) throws {
        try StoreFiles.write(all, to: fileURL)
        entries = all
        snapshot.withLock { $0 = all }
        loadError = nil
    }

    // MARK: Import / export

    public enum FileFormat: String, Sendable, CaseIterable { case csv, json }

    public struct ImportSummary: Sendable, Equatable { public var added: Int; public var updated: Int }

    public func export(to url: URL, format: FileFormat? = nil) throws {
        let data: Data
        switch format ?? Self.format(for: url) {
        case .csv: data = Data(Self.csv(entries).utf8)
        case .json: data = try StoreFiles.encoder.encode(entries)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Imports CSV or JSON. When `replacing` is false, entries whose term matches an existing one (same case
    /// sensitivity) update it; the rest are appended.
    @discardableResult
    public func importFile(at url: URL, format: FileFormat? = nil, replacing: Bool = false) throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        let incoming: [PronunciationEntry]
        switch format ?? Self.format(for: url) {
        case .json:
            do { incoming = try StoreFiles.decoder.decode([PronunciationEntry].self, from: data) }
            catch { throw StoreError.invalidFile("“\(url.lastPathComponent)” isn't a pronunciation list.") }
        case .csv:
            incoming = try Self.parseCSV(String(decoding: data, as: UTF8.self))
        }
        if replacing {
            try commit(incoming)
            return ImportSummary(added: incoming.count, updated: 0)
        }
        var all = entries
        var summary = ImportSummary(added: 0, updated: 0)
        for e in incoming {
            if let i = all.firstIndex(where: { Self.sameTerm($0, e) }) {
                all[i].replacement = e.replacement; all[i].enabled = e.enabled
                summary.updated += 1
            } else {
                all.append(e); summary.added += 1
            }
        }
        try commit(all)
        return summary
    }

    static func sameTerm(_ a: PronunciationEntry, _ b: PronunciationEntry) -> Bool {
        guard a.caseSensitive == b.caseSensitive else { return false }
        return a.caseSensitive ? a.term.trimmed() == b.term.trimmed()
            : a.term.trimmed().compare(b.term.trimmed(), options: .caseInsensitive) == .orderedSame
    }

    static func format(for url: URL) -> FileFormat { url.pathExtension.lowercased() == "json" ? .json : .csv }

    // MARK: CSV

    nonisolated static let csvHeader = ["term", "replacement", "case_sensitive", "enabled"]

    /// RFC 4180 CSV with a header row.
    public nonisolated static func csv(_ entries: [PronunciationEntry]) -> String {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) || s != s.trimmed()
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = [csvHeader.joined(separator: ",")]
        for e in entries {
            lines.append([field(e.term), field(e.replacement), e.caseSensitive ? "true" : "false", e.enabled ? "true" : "false"]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Reads CSV (comma, semicolon or tab separated) with or without a header. Columns: term, replacement,
    /// then optionally case-sensitive and enabled (true/false, yes/no, 1/0).
    public nonisolated static func parseCSV(_ text: String) throws -> [PronunciationEntry] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let firstLine = body.prefix { !$0.isNewline }
        let separator: Character = [",", ";", "\t"].max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count }!
        var rows = parseRows(body, separator: separator)
        if let header = rows.first, header.first?.trimmed().lowercased() == "term" { rows.removeFirst() }
        func flag(_ s: String?, _ fallback: Bool) -> Bool {
            switch s?.trimmed().lowercased() {
            case "true", "yes", "y", "1", "x": true
            case "false", "no", "n", "0": false
            default: fallback
            }
        }
        var out: [PronunciationEntry] = []
        for (n, row) in rows.enumerated() {
            if row.allSatisfy({ $0.trimmed().isEmpty }) { continue }
            guard row.count >= 2, !row[0].trimmed().isEmpty else {
                throw StoreError.invalidFile("Row \(n + 1) needs a term and a replacement.")
            }
            out.append(PronunciationEntry(term: row[0].trimmed(), replacement: row[1].trimmed(),
                                          caseSensitive: flag(row.count > 2 ? row[2] : nil, false),
                                          enabled: flag(row.count > 3 ? row[3] : nil, true)))
        }
        return out
    }

    private nonisolated static func parseRows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return chars.next() }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.trimmed().isEmpty {
                field = ""; quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c.isNewline {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
