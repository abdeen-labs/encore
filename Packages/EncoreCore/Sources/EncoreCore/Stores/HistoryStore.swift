import Foundation
import GRDB
import Observation

// MARK: - Items and queries

public enum HistoryKind: String, Codable, Sendable, CaseIterable {
    case speech, conversation, voiceChange, voiceDesign, transcription

    init(_ kind: GenerationRecord.Kind) {
        switch kind {
        case .speech: self = .speech
        case .conversation: self = .conversation
        case .voiceChange: self = .voiceChange
        case .voiceDesign: self = .voiceDesign
        }
    }
}

/// One row of history: a generation or a transcription, plus the user's title and star.
public struct HistoryItem: Sendable, Hashable, Identifiable {
    public enum Record: Sendable, Hashable {
        case generation(GenerationRecord)
        case transcription(TranscriptionRecord)
    }
    public var record: Record
    /// For generations this mirrors `GenerationRecord.title`; for transcriptions it starts as the source file name.
    public var title: String
    public var favorite: Bool

    public var id: UUID {
        switch record { case .generation(let r): r.id; case .transcription(let r): r.id }
    }
    public var kind: HistoryKind {
        switch record { case .generation(let r): HistoryKind(r.kind); case .transcription: .transcription }
    }
    public var createdAt: Date {
        switch record { case .generation(let r): r.createdAt; case .transcription(let r): r.createdAt }
    }
    public var modelName: String {
        switch record { case .generation(let r): r.modelName; case .transcription(let r): r.modelName }
    }
    public var generation: GenerationRecord? { if case .generation(let r) = record { r } else { nil } }
    public var transcription: TranscriptionRecord? { if case .transcription(let r) = record { r } else { nil } }
}

public struct HistoryQuery: Sendable, Hashable {
    /// Words to find in titles, scripts, transcripts, voice and model names. Each word matches as a prefix.
    public var search: String = ""
    /// Empty = every kind.
    public var kinds: Set<HistoryKind> = []
    public var favoritesOnly = false
    public var modelID: String?
    public var voiceID: UUID?
    /// Inclusive lower bound.
    public var from: Date?
    /// Exclusive upper bound.
    public var until: Date?
    /// Exact voice name, for voices that aren't in the library (a model's preset voices have no `voiceID`).
    public var voiceName: String?

    public init(search: String = "", kinds: Set<HistoryKind> = [], favoritesOnly: Bool = false, modelID: String? = nil,
                voiceID: UUID? = nil, from: Date? = nil, until: Date? = nil, voiceName: String? = nil) {
        self.search = search; self.kinds = kinds; self.favoritesOnly = favoritesOnly; self.modelID = modelID
        self.voiceID = voiceID; self.from = from; self.until = until; self.voiceName = voiceName
    }

    /// True when anything other than the search narrows the results.
    public var hasFilters: Bool {
        !kinds.isEmpty || favoritesOnly || modelID != nil || voiceID != nil || voiceName != nil || from != nil || until != nil
    }
}

/// What the history holds, for filter menus: the models and voices used (most used first) and items per kind.
public struct HistoryFacets: Sendable, Equatable {
    public struct Model: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var count: Int
    }
    public struct Voice: Sendable, Hashable, Identifiable {
        /// The library voice, when it is one.
        public var voiceID: UUID?
        public var name: String
        public var count: Int
        public var id: String { voiceID?.uuidString ?? "name:" + name }
    }
    public var models: [Model] = []
    public var voices: [Voice] = []
    public var kinds: [HistoryKind: Int] = [:]
    public var total: Int { kinds.values.reduce(0, +) }
    public init() {}
}

// MARK: - Database

/// Generation and transcription history in SQLite (GRDB), with FTS5 search. Audio masters live in
/// `<directory>/Audio/`; deleting a generation deletes its master when it lives there.
///
/// Sendable; every method can be called from any isolation (async methods run on GRDB's queues).
public final class HistoryDatabase: Sendable {
    public let directory: URL
    public let audioDirectory: URL
    let pool: DatabasePool

    public init(directory: URL = EncorePaths.history) throws {
        self.directory = directory
        audioDirectory = directory.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "Encore history"
        pool = try DatabasePool(path: directory.appendingPathComponent("history.sqlite").path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull().indexed()
                t.column("title", .text).notNull()
                // Script text for generations, transcript text for transcriptions.
                t.column("body", .text).notNull()
                t.column("modelID", .text).notNull().indexed()
                t.column("modelName", .text).notNull()
                t.column("voiceName", .text)
                t.column("voiceID", .text).indexed()
                t.column("audioPath", .text)
                t.column("createdAt", .double).notNull().indexed()
                t.column("favorite", .boolean).notNull().defaults(to: false)
                // The full record as JSON, so the record types can grow without schema changes.
                t.column("record", .blob).notNull()
            }
            try db.create(virtualTable: "itemSearch", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("body")
                t.column("voiceName")
                t.column("modelName")
            }
        }
        return m
    }

    // MARK: Audio files

    /// Where to write the WAV master for a new generation. The directory exists.
    public func newAudioURL(id: UUID = UUID(), fileExtension: String = "wav") -> URL {
        audioDirectory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    func ownsAudio(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let dir = audioDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return file.hasPrefix(dir + "/")
    }

    // MARK: Writing

    public func insert(_ record: GenerationRecord) async throws {
        try await pool.write { db in try Self.row(for: .generation(record), title: record.title, favorite: record.favorite).insert(db) }
    }

    public func insert(_ record: TranscriptionRecord) async throws {
        try await pool.write { db in try Self.row(for: .transcription(record), title: record.sourceName, favorite: false).insert(db) }
    }

    /// Replaces a generation's stored record (title and favorite follow the record).
    public func update(_ record: GenerationRecord) async throws {
        try await pool.write { db in
            guard try ItemRow.exists(db, key: record.id.uuidString) else { throw StoreError.notFound("The history item") }
            try Self.row(for: .generation(record), title: record.title, favorite: record.favorite).update(db)
        }
    }

    /// Replaces a transcription's stored record (e.g. after the user edits the transcript), keeping title and star.
    public func update(_ record: TranscriptionRecord) async throws {
        try await pool.write { db in
            guard let old = try ItemRow.fetchOne(db, key: record.id.uuidString) else { throw StoreError.notFound("The history item") }
            try Self.row(for: .transcription(record), title: old.title, favorite: old.favorite).update(db)
        }
    }

    public func setTitle(_ title: String, for id: UUID) async throws {
        try await modify(id) { $0.title = title.collapsingWhitespace() }
    }

    public func setFavorite(_ favorite: Bool, for id: UUID) async throws {
        try await modify(id) { $0.favorite = favorite }
    }

    private func modify(_ id: UUID, _ change: @escaping @Sendable (inout HistoryItem) -> Void) async throws {
        try await pool.write { db in
            guard let row = try ItemRow.fetchOne(db, key: id.uuidString) else { throw StoreError.notFound("The history item") }
            var item = try row.item()
            change(&item)
            if case .generation(var g) = item.record { g.title = item.title; g.favorite = item.favorite; item.record = .generation(g) }
            try Self.row(for: item.record, title: item.title, favorite: item.favorite).update(db)
        }
    }

    /// Deletes items and the audio masters they own. Missing ids are ignored.
    public func delete(_ ids: [UUID]) async throws {
        let paths: [String] = try await pool.write { db in
            var paths: [String] = []
            for id in ids {
                guard let row = try ItemRow.fetchOne(db, key: id.uuidString) else { continue }
                if let p = row.audioPath { paths.append(p) }
                try row.delete(db)
            }
            return paths
        }
        for p in paths where ownsAudio(p) { try? FileManager.default.removeItem(atPath: p) }
    }

    public func delete(_ id: UUID) async throws { try await delete([id]) }

    // MARK: Reading

    public func item(_ id: UUID) async throws -> HistoryItem? {
        try await pool.read { db in try ItemRow.fetchOne(db, key: id.uuidString)?.item() }
    }

    /// Newest first.
    public func fetch(_ query: HistoryQuery = .init(), limit: Int = 50, offset: Int = 0) async throws -> [HistoryItem] {
        try await pool.read { db in try Self.fetch(db, query, limit: limit, offset: offset) }
    }

    public func count(_ query: HistoryQuery = .init()) async throws -> Int {
        try await pool.read { db in try Self.count(db, query) }
    }

    static func fetch(_ db: Database, _ query: HistoryQuery, limit: Int, offset: Int) throws -> [HistoryItem] {
        guard let (sql, args) = try select(db, query, columns: "item.*") else { return [] }
        let rows = try ItemRow.fetchAll(db, sql: sql + " ORDER BY item.createdAt DESC, item.id LIMIT ? OFFSET ?",
                                        arguments: args + [limit, offset])
        return rows.compactMap { try? $0.item() }
    }

    static func count(_ db: Database, _ query: HistoryQuery) throws -> Int {
        guard let (sql, args) = try select(db, query, columns: "COUNT(*)") else { return 0 }
        return try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
    }

    /// Builds the SELECT for a query. Nil when the search can't match anything.
    private static func select(_ db: Database, _ q: HistoryQuery, columns: String) throws -> (String, StatementArguments)? {
        var sql = "SELECT \(columns) FROM item"
        var clauses: [String] = []
        var args: StatementArguments = []
        let search = q.search.trimmed()
        if !search.isEmpty {
            if search.contains(where: TextClass.isNoSpaceScript) {
                // The tokenizer keeps runs of CJK/Thai as single tokens, so search those by substring instead.
                for term in search.split(whereSeparator: \.isWhitespace) {
                    let like = "%" + term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_") + "%"
                    clauses.append("(item.title LIKE ? ESCAPE '\\' OR item.body LIKE ? ESCAPE '\\' OR IFNULL(item.voiceName, '') LIKE ? ESCAPE '\\' OR item.modelName LIKE ? ESCAPE '\\')")
                    args += [like, like, like, like]
                }
            } else {
                let tokens = try db.makeTokenizer(.unicode61(diacritics: .remove)).tokenize(query: search)
                    .filter { !$0.flags.contains(.colocated) }.map(\.token)
                if !tokens.isEmpty {
                    // Each token quoted (so FTS syntax in the query is inert) and matched as a prefix.
                    let pattern = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
                    sql += " JOIN itemSearch ON itemSearch.rowid = item.rowid AND itemSearch MATCH ?"
                    args += [pattern]
                }
            }
        }
        if !q.kinds.isEmpty {
            clauses.append("item.kind IN (\(q.kinds.map { _ in "?" }.joined(separator: ",")))")
            args += StatementArguments(q.kinds.map(\.rawValue).sorted())
        }
        if q.favoritesOnly { clauses.append("item.favorite = 1") }
        if let m = q.modelID { clauses.append("item.modelID = ?"); args += [m] }
        if let v = q.voiceID { clauses.append("item.voiceID = ?"); args += [v.uuidString] }
        if let n = q.voiceName { clauses.append("item.voiceName = ?"); args += [n] }
        if let f = q.from { clauses.append("item.createdAt >= ?"); args += [f.timeIntervalSince1970] }
        if let u = q.until { clauses.append("item.createdAt < ?"); args += [u.timeIntervalSince1970] }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        return (sql, args)
    }

    public func facets() async throws -> HistoryFacets {
        try await pool.read { db in try Self.facets(db) }
    }

    /// Observes the facets: emits them now and whenever the history changes them.
    public func observeFacets() -> AsyncValueObservation<HistoryFacets> {
        ValueObservation.tracking { db in try Self.facets(db) }.removeDuplicates().values(in: pool)
    }

    static func facets(_ db: Database) throws -> HistoryFacets {
        var f = HistoryFacets()
        for row in try Row.fetchAll(db, sql: "SELECT modelID, MAX(modelName) AS name, COUNT(*) AS n FROM item GROUP BY modelID ORDER BY n DESC, name") {
            f.models.append(.init(id: row["modelID"], name: row["name"], count: row["n"]))
        }
        // Conversations list every speaker in one name; they aren't one voice.
        let sql = """
            SELECT voiceID, voiceName AS name, COUNT(*) AS n FROM item
            WHERE voiceName IS NOT NULL AND voiceName != '' AND kind != 'conversation'
            GROUP BY IFNULL(voiceID, ''), voiceName ORDER BY n DESC, name
            """
        for row in try Row.fetchAll(db, sql: sql) {
            let id: String? = row["voiceID"]
            f.voices.append(.init(voiceID: id.flatMap(UUID.init(uuidString:)), name: row["name"], count: row["n"]))
        }
        for row in try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM item GROUP BY kind") {
            if let k = HistoryKind(rawValue: row["kind"]) { f.kinds[k] = row["n"] }
        }
        return f
    }

    /// Observes a query: emits the first `limit` items and the total count, again whenever they change.
    public func observe(_ query: HistoryQuery, limit: Int) -> AsyncValueObservation<HistoryPage> {
        ValueObservation.tracking { db in
            HistoryPage(items: try Self.fetch(db, query, limit: limit, offset: 0), total: try Self.count(db, query))
        }
        .removeDuplicates()
        .values(in: pool)
    }

    // MARK: Rows

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func row(for record: HistoryItem.Record, title: String, favorite: Bool) throws -> ItemRow {
        switch record {
        case .generation(let r):
            return ItemRow(id: r.id.uuidString, kind: HistoryKind(r.kind).rawValue, title: title, body: r.text, modelID: r.modelID,
                           modelName: r.modelName, voiceName: r.voiceName, voiceID: r.voiceID?.uuidString, audioPath: r.audioPath,
                           createdAt: r.createdAt.timeIntervalSince1970, favorite: favorite, record: try encoder.encode(r))
        case .transcription(let r):
            let text = r.transcript.text.trimmed().isEmpty ? r.transcript.segments.map(\.text).joined(separator: " ") : r.transcript.text
            return ItemRow(id: r.id.uuidString, kind: HistoryKind.transcription.rawValue, title: title, body: text, modelID: r.modelID,
                           modelName: r.modelName, voiceName: nil, voiceID: nil, audioPath: nil,
                           createdAt: r.createdAt.timeIntervalSince1970, favorite: favorite, record: try encoder.encode(r))
        }
    }

    struct ItemRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "item"
        var id: String
        var kind: String
        var title: String
        var body: String
        var modelID: String
        var modelName: String
        var voiceName: String?
        var voiceID: String?
        var audioPath: String?
        var createdAt: Double
        var favorite: Bool
        var record: Data

        func item() throws -> HistoryItem {
            if kind == HistoryKind.transcription.rawValue {
                return HistoryItem(record: .transcription(try decoder.decode(TranscriptionRecord.self, from: record)),
                                   title: title, favorite: favorite)
            }
            return HistoryItem(record: .generation(try decoder.decode(GenerationRecord.self, from: record)), title: title, favorite: favorite)
        }
    }
}

public struct HistoryPage: Sendable, Equatable {
    public var items: [HistoryItem]
    /// Matching items in total (for "load more").
    public var total: Int
}

// MARK: - Observable view

/// The history as SwiftUI sees it: set `query`, read `items`; they refresh whenever the database changes,
/// whoever changed it. `loadMore()` grows the window by `pageSize`.
@MainActor @Observable
public final class HistoryStore {
    @ObservationIgnored public nonisolated let database: HistoryDatabase

    public var query = HistoryQuery() { didSet { if query != oldValue { limit = pageSize; restart() } } }
    public private(set) var items: [HistoryItem] = []
    public private(set) var totalCount = 0
    /// True until the first results for the current query arrive.
    public private(set) var isLoading = true
    public private(set) var lastError: String?
    public var hasMore: Bool { items.count < totalCount }

    @ObservationIgnored public let pageSize: Int
    @ObservationIgnored private var limit: Int
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(database: HistoryDatabase, pageSize: Int = 50) {
        self.database = database
        self.pageSize = pageSize
        limit = pageSize
        restart()
    }

    isolated deinit { task?.cancel() }

    public func loadMore() {
        guard hasMore else { return }
        limit += pageSize
        restart()
    }

    private func restart() {
        task?.cancel()
        isLoading = true
        let observation = database.observe(query, limit: limit)
        task = Task { [weak self] in
            do {
                for try await page in observation {
                    guard let self else { return }
                    self.items = page.items
                    self.totalCount = page.total
                    self.isLoading = false
                    self.lastError = nil
                }
            } catch is CancellationError {
            } catch {
                self?.lastError = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    // Conveniences for the UI; the service layer talks to `database` directly.
    public func setFavorite(_ favorite: Bool, for id: UUID) async throws { try await database.setFavorite(favorite, for: id) }
    public func setTitle(_ title: String, for id: UUID) async throws { try await database.setTitle(title, for: id) }
    public func delete(_ ids: [UUID]) async throws { try await database.delete(ids) }
}
