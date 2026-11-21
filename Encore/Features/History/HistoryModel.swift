import AppKit
import EncoreCore
import GRDB
import SwiftUI

/// Everything the History screen does, without the views: the query (search as you type, kind, favorites, model,
/// voice, date), paging, the focused item and the multi-selection, and every action on items (rename, favorite,
/// export, reveal, copy, reuse in Studio, delete). One instance lives for the app's lifetime
/// (`deps.screenModel("History")`), so the search and selection survive switching sections.
@MainActor @Observable
final class HistoryModel {
    enum KindFilter: String, CaseIterable, Hashable {
        case all, speech, conversation, voiceChange, voiceDesign, transcription

        var title: String {
            switch self {
            case .all: "All"
            case .speech: "Speech"
            case .conversation: "Conversations"
            case .voiceChange: "Voice changes"
            case .voiceDesign: "Designs"
            case .transcription: "Transcripts"
            }
        }

        var kind: HistoryKind? {
            switch self {
            case .all: nil
            case .speech: .speech
            case .conversation: .conversation
            case .voiceChange: .voiceChange
            case .voiceDesign: .voiceDesign
            case .transcription: .transcription
            }
        }
    }

    enum DateFilter: String, CaseIterable, Hashable {
        case any, today, week, month, year

        var title: String {
            switch self {
            case .any: "Any time"
            case .today: "Today"
            case .week: "Past 7 days"
            case .month: "Past 30 days"
            case .year: "Past year"
            }
        }

        func start(now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .any: nil
            case .today: calendar.startOfDay(for: now)
            case .week: now.addingTimeInterval(-7 * 86_400)
            case .month: now.addingTimeInterval(-30 * 86_400)
            case .year: now.addingTimeInterval(-365 * 86_400)
            }
        }
    }

    let service: EncoreService
    let store: HistoryStore
    @ObservationIgnored private let studio: () -> StudioModel
    @ObservationIgnored private let router: Router?
    /// Shows a transcription on the Transcribe screen (`deps.openInTranscribe`); nil where there is no app shell.
    @ObservationIgnored var openTranscription: ((TranscriptionRecord) -> Void)?

    // MARK: Query

    var search = "" { didSet { if search != oldValue { applyQuery() } } }
    var kind: KindFilter = .all { didSet { if kind != oldValue { applyQuery() } } }
    var favoritesOnly = false { didSet { if favoritesOnly != oldValue { applyQuery() } } }
    var modelID: String? { didSet { if modelID != oldValue { applyQuery() } } }
    var voice: HistoryFacets.Voice? { didSet { if voice != oldValue { applyQuery() } } }
    var date: DateFilter = .any { didSet { if date != oldValue { applyQuery() } } }

    /// Models and voices that appear in the history, for the filter menus.
    private(set) var facets = HistoryFacets()

    // MARK: Selection

    /// The item shown in the detail panel.
    var focusedID: UUID?
    /// Items picked for a bulk action.
    var selection: Set<UUID> = []
    /// Shows a selection mark on every row; clicking a row then toggles it.
    var isSelecting = false
    /// Items waiting for the delete confirmation.
    var pendingDelete: [UUID] = []
    /// Anchor for shift-click ranges.
    @ObservationIgnored private var anchorID: UUID?

    @ObservationIgnored private var facetsTask: Task<Void, Never>?

    init(service: EncoreService, store: HistoryStore? = nil, router: Router? = nil, studio: @escaping () -> StudioModel) {
        self.service = service
        self.store = store ?? HistoryStore(database: service.history)
        self.router = router
        self.studio = studio
        observeFacets()
    }

    convenience init(deps: AppDependencies) {
        self.init(service: deps.service, router: deps.router) { [unowned deps] in
            deps.screenModel("Studio") { StudioModel(deps: deps) }
        }
        openTranscription = { [unowned deps] in deps.openInTranscribe($0) }
    }

    isolated deinit { facetsTask?.cancel() }

    // MARK: Derived

    var items: [HistoryItem] { store.items }
    var totalCount: Int { store.totalCount }
    var isLoading: Bool { store.isLoading }
    var hasMore: Bool { store.hasMore }

    var focused: HistoryItem? { focusedID.flatMap { id in items.first { $0.id == id } } }

    /// The history holds nothing at all (as opposed to nothing matching).
    var isEmpty: Bool { !store.isLoading && facets.total == 0 && store.totalCount == 0 }
    var isFiltered: Bool { store.query.hasFilters || !store.query.search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Words the search looks for, for highlighting.
    var searchTerms: [String] { HistoryHighlight.terms(search) }

    var selectedItems: [HistoryItem] { items.filter { selection.contains($0.id) } }

    /// Kinds worth a tab: the ones the history has, plus the current one.
    var kindTabs: [KindFilter] {
        KindFilter.allCases.filter { k in k == .all || k == kind || (k.kind.map { (facets.kinds[$0] ?? 0) > 0 } ?? false) }
    }

    func count(_ k: KindFilter) -> Int { k.kind.map { facets.kinds[$0] ?? 0 } ?? facets.total }

    var modelName: String? { modelID.map { id in facets.models.first { $0.id == id }?.name ?? service.catalog.model(id)?.name ?? id } }

    // MARK: Query plumbing

    func clearFilters() {
        kind = .all; favoritesOnly = false; modelID = nil; voice = nil; date = .any
    }

    func loadMore() { store.loadMore() }

    private func applyQuery() {
        var q = HistoryQuery(search: search, favoritesOnly: favoritesOnly, modelID: modelID, from: date.start(now: Date()))
        if let k = kind.kind { q.kinds = [k] }
        if let voice {
            if let id = voice.voiceID { q.voiceID = id } else { q.voiceName = voice.name }
        }
        store.query = q
    }

    private func observeFacets() {
        let observation = service.history.observeFacets()
        facetsTask = Task { [weak self] in
            do {
                for try await f in observation {
                    guard let self else { return }
                    self.facets = f
                }
            } catch {}
        }
    }

    // MARK: Focus and selection

    /// A click on a row: plain focuses it; ⌘ toggles it in the selection; ⇧ selects the range from the last click.
    func click(_ item: HistoryItem, command: Bool = false, shift: Bool = false) {
        if shift, let anchor = anchorID, let a = items.firstIndex(where: { $0.id == anchor }),
           let b = items.firstIndex(where: { $0.id == item.id }) {
            let range = min(a, b)...max(a, b)
            selection.formUnion(items[range].map(\.id))
            isSelecting = true
            return
        }
        if command || isSelecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            if !selection.isEmpty { isSelecting = true }
            anchorID = item.id
            return
        }
        anchorID = item.id
        focusedID = focusedID == item.id ? nil : item.id
    }

    func selectAll() {
        selection = Set(items.map(\.id))
        isSelecting = true
    }

    func endSelecting() {
        selection = []
        isSelecting = false
    }

    // MARK: Item actions

    func toggleFavorite(_ item: HistoryItem) {
        Task { try? await store.setFavorite(!item.favorite, for: item.id) }
    }

    func rename(_ item: HistoryItem, to title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        try await store.setTitle(trimmed, for: item.id)
    }

    /// Asks before deleting (the confirmation is the screen's sheet).
    func requestDelete(_ ids: [UUID]) { pendingDelete = ids }

    /// Deletes items; their audio files go to the Trash. Returns how many went.
    @discardableResult
    func confirmDelete() async throws -> Int {
        let ids = pendingDelete
        pendingDelete = []
        guard !ids.isEmpty else { return 0 }
        try await store.delete(ids)
        selection.subtract(ids)
        if let f = focusedID, ids.contains(f) { focusedID = nil }
        if selection.isEmpty { isSelecting = false }
        return ids.count
    }

    /// The script, or the transcript as plain text.
    func text(of item: HistoryItem) -> String {
        switch item.record {
        case .generation(let g): g.text
        case .transcription(let t): TranscriptFormatter().plainText(t.transcript)
        }
    }

    func copyText(_ item: HistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(of: item), forType: .string)
    }

    func reveal(_ item: HistoryItem) {
        switch item.record {
        case .generation(let g): AudioExportActions.revealInFinder(g.audioURL)
        case .transcription(let t): AudioExportActions.revealInFinder(URL(fileURLWithPath: t.sourcePath))
        }
    }

    /// Whether "Reuse in Studio" applies: speech made with a model this build still has.
    func canReuse(_ item: HistoryItem) -> Bool {
        guard let g = item.generation, g.kind == .speech else { return false }
        return service.catalog.model(g.modelID)?.tasks.contains(.tts) == true
    }

    /// Loads a take's settings into the Studio and goes there. Returns a problem to show, or nil.
    func reuseInStudio(_ item: HistoryItem) -> String? {
        guard let g = item.generation else { return "Only speech can be reused in the Studio." }
        if let problem = studio().reuse(g) { return problem }
        router?.go(.studio)
        return nil
    }

    /// Whether "Open in Transcribe" applies: a transcription, where the app can show one.
    func canOpenInTranscribe(_ item: HistoryItem) -> Bool { item.transcription != nil && openTranscription != nil }

    /// Shows a transcription on the Transcribe screen, with its player and exports.
    func openInTranscribe(_ item: HistoryItem) {
        guard let t = item.transcription else { return }
        openTranscription?(t)
    }

    // MARK: Export

    struct ExportResult: Equatable {
        var written: [URL]
        var failures: [String]
        /// Stopped part-way (the progress card's cancel button); files already written stay.
        var canceled = false
    }

    /// Writes each item into `folder`: audio in `format` (the WAV master is copied as is), transcripts as text.
    /// Existing files are never overwritten; a number is added instead. `progress` covers the whole batch, each item
    /// an equal share. Canceling the task stops at once: the file in progress is never left half-written; the ones
    /// before it stay.
    func export(_ items: [HistoryItem], format: AudioFileFormat, transcriptFormat: TranscriptFormat = .text,
                to folder: URL, progress: ExportProgress? = nil) async -> ExportResult {
        var result = ExportResult(written: [], failures: [])
        let share = 1 / Double(max(1, items.count))
        for (index, item) in items.enumerated() {
            if Task.isCancelled { result.canceled = true; break }
            let done = Double(index) * share
            let itemProgress: ExportProgress? = progress.map { p in { @Sendable f in p(done + share * f) } }
            defer { progress?(done + share) }
            var base = AudioExportActions.sanitized(item.title)
            // A transcript's title is usually its source file name: drop that file's extension.
            let ext = (base as NSString).pathExtension
            if item.kind == .transcription, !ext.isEmpty, ext.count <= 4 { base = (base as NSString).deletingPathExtension }
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if base.isEmpty { base = "Encore" }
            do {
                switch item.record {
                case .generation(let g):
                    let url = Self.unique(folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension))
                    if format == .wav { try FileManager.default.copyItem(at: g.audioURL, to: url) }
                    else { try await AudioExporter.convert(g.audioURL, to: url, format: format, progress: itemProgress) }
                    result.written.append(url)
                case .transcription(let t):
                    let url = Self.unique(folder.appendingPathComponent(base).appendingPathExtension(transcriptFormat.fileExtension))
                    try TranscriptFormatter().data(t.transcript, as: transcriptFormat).write(to: url, options: .withoutOverwriting)
                    result.written.append(url)
                }
            } catch is CancellationError {
                result.canceled = true
                break
            } catch {
                result.failures.append("\(item.title): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), ext = url.pathExtension, name = url.deletingPathExtension().lastPathComponent
        for n in 2... {
            let candidate = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    #if DEBUG
    /// Fixtures and the headless runner: waits until the store reflects the current query.
    func waitForResults() async {
        for _ in 0..<200 {
            if !store.isLoading { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(30))
    }
    #endif
}

// MARK: - Search highlighting

/// Finds the search words in text the way the history search does (each word as a prefix, ignoring case and
/// accents) and marks them.
enum HistoryHighlight {
    static func terms(_ search: String) -> [String] {
        search.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }

    /// Ranges of `text` where a term starts a word (or anywhere, for scripts without spaces).
    static func ranges(in text: String, terms: [String]) -> [Range<String.Index>] {
        guard !terms.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        for term in terms {
            var from = text.startIndex
            // CJK, kana, Hangul and Thai are searched by substring (no spaces between words).
            let anywhere = term.unicodeScalars.contains { s in
                s.properties.isIdeographic || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
                    || (0x0E00...0x0E7F).contains(s.value)
            }
            while from < text.endIndex,
                  let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: from..<text.endIndex) {
                let atWordStart = r.lowerBound == text.startIndex || {
                    let prev = text[text.index(before: r.lowerBound)]
                    return !(prev.isLetter || prev.isNumber)
                }()
                if anywhere || atWordStart {
                    // Extend to the end of the word, as a prefix match would.
                    var end = r.upperBound
                    while !anywhere, end < text.endIndex, text[end].isLetter || text[end].isNumber { end = text.index(after: end) }
                    out.append(r.lowerBound..<end)
                }
                from = r.upperBound
            }
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }

    static func attributed(_ text: String, terms: [String], base: Color = .textPrimary) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = base
        for r in ranges(in: text, terms: terms) {
            guard let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo..<hi].foregroundColor = .tungsten
            a[lo..<hi].backgroundColor = Color.tungsten.opacity(0.16)
        }
        return a
    }

    /// A short window of `text` around its first match (or its start, with no match), on one line.
    static func snippet(_ text: String, terms: [String], length: Int = 240) -> (text: String, matched: Bool) {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        func cut(_ s: Substring) -> String { s.count > length ? String(s.prefix(length)) + "…" : String(s) }
        guard let first = ranges(in: flat, terms: terms).first else { return (cut(flat[...]), false) }
        let lead = 36
        var start = flat.index(first.lowerBound, offsetBy: -lead, limitedBy: flat.startIndex) ?? flat.startIndex
        if start > flat.startIndex, let space = flat[start..<first.lowerBound].firstIndex(of: " ") { start = flat.index(after: space) }
        return ((start > flat.startIndex ? "…" : "") + cut(flat[start...]), true)
    }
}
