import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// The Voices screen's state, without the views: filters and sort, the selection and the voice in the inspector,
/// import/export of `.encorevoice` files, duplicate and delete. Kept for the app's lifetime (`deps.screenModel("Voices")`).
@MainActor @Observable
final class VoicesModel {
    enum OriginFilter: String, CaseIterable, Hashable { case all = "All", cloned = "Cloned", designed = "Designed", imported = "Imported" }
    enum Sort: String, CaseIterable, Hashable { case newest = "Newest first", oldest = "Oldest first", name = "Name", length = "Length" }

    /// What an import brought in, and what it refused (with the importer's own words).
    struct ImportReport: Equatable {
        struct Refusal: Hashable { var file: String; var reason: String }
        var imported: [Voice]
        var refused: [Refusal]
    }

    /// Files that were read and hold at least one cloned voice, waiting for the importer's consent (one tick covers
    /// the whole batch). Files that couldn't be read wait here too, so the report lists them afterwards.
    struct PendingImport: Equatable {
        struct File: Equatable { var url: URL; var voices: [Voice] }
        var files: [File]
        var refused: [ImportReport.Refusal]
        var consent = false

        var voices: [Voice] { files.flatMap(\.voices) }
        /// The voices that need the speaker's permission.
        var clones: [Voice] { voices.filter(\.needsSpeakerConsent) }
    }

    let library: VoiceLibrary

    var query = ""
    var tags: Set<String> = []
    var origin: OriginFilter = .all
    var sort: Sort = .newest
    /// Voices ticked for bulk actions.
    var selection: Set<UUID> = []
    /// The voice open in the inspector.
    var focused: UUID?
    /// A card's check circle was used: cards show their checks and the batch bar stays up even for one voice.
    private(set) var isPicking = false
    var importReport: ImportReport?
    /// Set while the import consent sheet is up.
    var pendingImport: PendingImport?
    var exportNote: String?
    private(set) var busy: String?
    var showImporter = false
    /// Voices waiting for the delete confirmation.
    var pendingDelete: [UUID] = []

    @ObservationIgnored private var anchor: UUID?

    init(library: VoiceLibrary) { self.library = library }
    convenience init(deps: AppDependencies) { self.init(library: deps.voices) }

    // MARK: Browsing

    var isFiltered: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || !tags.isEmpty || origin != .all }

    var visible: [Voice] {
        var list = library.search(query, tags: tags)
        switch origin {
        case .all: break
        case .cloned: list = list.filter { $0.origin == .cloned }
        case .designed: list = list.filter { $0.origin == .designed }
        case .imported: list = list.filter { $0.origin == .imported }
        }
        switch sort {
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .oldest: list.sort { $0.createdAt < $1.createdAt }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .length: list.sort { $0.duration > $1.duration }
        }
        return list
    }

    func count(_ o: OriginFilter) -> Int {
        switch o {
        case .all: library.voices.count
        case .cloned: library.voices.filter { $0.origin == .cloned }.count
        case .designed: library.voices.filter { $0.origin == .designed }.count
        case .imported: library.voices.filter { $0.origin == .imported }.count
        }
    }

    func clearFilters() {
        query = ""
        tags = []
        origin = .all
    }

    var focusedVoice: Voice? { focused.flatMap { id in library.voices.first { $0.id == id } } }

    /// Opens a voice in the inspector (and selects only it).
    func focus(_ id: UUID?) {
        focused = id
        selection = id.map { [$0] } ?? []
        anchor = id
        isPicking = false
    }

    /// Cards show their check circles and the batch bar is up: picking has started, or several voices are selected.
    var showsChecks: Bool { isPicking || selection.count > 1 }

    /// The voice's card is drawn checked.
    func isChecked(_ id: UUID) -> Bool { showsChecks && selection.contains(id) }

    /// The batch bar's Done: clears the selection and closes the inspector.
    func endPicking() {
        selection = []
        focused = nil
        isPicking = false
    }

    /// Click on a card: plain selects one and opens it; ⌘ toggles; ⇧ extends from the last click.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags, in list: [Voice]) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            focused = selection.count == 1 ? selection.first : (selection.contains(id) ? id : focused.flatMap { selection.contains($0) ? $0 : nil })
            anchor = id
            settlePicking()
        } else if modifiers.contains(.shift), let a = anchor, let i = list.firstIndex(where: { $0.id == a }),
                  let j = list.firstIndex(where: { $0.id == id }) {
            selection.formUnion(list[min(i, j)...max(i, j)].map(\.id))
            focused = id
            settlePicking()
        } else {
            focus(id)
        }
    }

    /// A card's check circle: adds the voice to the selection (like ⌘-click) and shows the checks; once they show,
    /// it toggles. A voice that was merely open in the inspector becomes checked on the first click, not cleared.
    func toggle(_ id: UUID) {
        if showsChecks, selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        isPicking = true
        focused = selection.count == 1 ? selection.first : focused.flatMap { selection.contains($0) ? $0 : nil }
        anchor = id
        settlePicking()
    }

    /// Picking mode lasts while anything is selected and starts whenever several voices are.
    private func settlePicking() {
        if selection.isEmpty { isPicking = false } else if selection.count > 1 { isPicking = true }
    }

    /// Drops selected/focused ids that no longer exist.
    func prune() {
        let ids = Set(library.voices.map(\.id))
        selection.formIntersection(ids)
        if let f = focused, !ids.contains(f) { focused = nil }
        settlePicking()
    }

    // MARK: Import

    /// Reads the files first. If any holds a cloned voice, the consent sheet comes up (`pendingImport`) and nothing is
    /// imported until `confirmImport()`; files of designed voices only are imported straight away.
    func importFiles(_ urls: [URL]) async {
        let files = urls.filter { $0.pathExtension.lowercased() == VoiceLibrary.fileExtension }
        guard !files.isEmpty, pendingImport == nil else { return }
        busy = files.count == 1 ? "Reading \(files[0].lastPathComponent)…" : "Reading \(files.count) files…"
        var readable: [PendingImport.File] = []
        var refused: [ImportReport.Refusal] = []
        for url in files {
            do {
                readable.append(.init(url: url, voices: try await library.inspectArchive(url)))
            } catch {
                refused.append(.init(file: url.lastPathComponent, reason: Self.describe(error)))
            }
        }
        busy = nil
        let pending = PendingImport(files: readable, refused: refused)
        if pending.clones.isEmpty {
            await finishImport(pending, consentConfirmedAt: nil)
        } else {
            withStageAnimation { pendingImport = pending }
        }
    }

    /// The consent sheet's Import: brings the files in with the importer's consent, dated now.
    func confirmImport() async {
        guard let pending = pendingImport, pending.consent else { return }
        pendingImport = nil
        await finishImport(pending, consentConfirmedAt: Date())
    }

    /// The consent sheet was closed: nothing is imported; files that couldn't be read are still reported.
    func cancelImport() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        if !pending.refused.isEmpty { withStageAnimation { importReport = ImportReport(imported: [], refused: pending.refused) } }
    }

    private func finishImport(_ pending: PendingImport, consentConfirmedAt: Date?) async {
        guard !pending.files.isEmpty else {
            withStageAnimation { importReport = ImportReport(imported: [], refused: pending.refused) }
            return
        }
        busy = pending.files.count == 1 ? "Importing \(pending.files[0].url.lastPathComponent)…" : "Importing \(pending.files.count) files…"
        defer { busy = nil }
        var report = ImportReport(imported: [], refused: pending.refused)
        for file in pending.files {
            do {
                report.imported += try await library.importVoices(from: file.url, consentConfirmedAt: consentConfirmedAt)
            } catch {
                report.refused.append(.init(file: file.url.lastPathComponent, reason: Self.describe(error)))
            }
        }
        withStageAnimation { importReport = report }
        if let first = report.imported.first, report.imported.count == 1 { focus(first.id) }
        else if !report.imported.isEmpty { selection = Set(report.imported.map(\.id)); focused = nil }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return error.localizedDescription
    }

    // MARK: Export

    /// Asks where to save, then writes one `.encorevoice` file holding `ids`.
    func exportWithPanel(_ ids: [UUID]) {
        let voices = ids.compactMap { library.voice($0) }
        guard !voices.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.encoreVoice]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (voices.count == 1 ? voices[0].name : "\(voices.count) voices") + "." + VoiceLibrary.fileExtension
        panel.message = voices.count == 1 ? "Export “\(voices[0].name)” as a voice file anyone with Encore can import."
            : "Export \(voices.count) voices as one voice file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await export(ids, to: url, reveal: true) }
    }

    func export(_ ids: [UUID], to url: URL, reveal: Bool = false) async {
        busy = "Exporting…"
        defer { busy = nil }
        do {
            try await library.export(ids, to: url)
            exportNote = ids.count == 1 ? "Exported to \(url.lastPathComponent)" : "Exported \(ids.count) voices to \(url.lastPathComponent)"
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            exportNote = "Export failed: \(Self.describe(error))"
        }
    }

    // MARK: Edit

    func duplicate(_ id: UUID) async -> Voice? {
        guard let copy = try? await library.duplicate(id) else { return nil }
        focus(copy.id)
        return copy
    }

    /// Moves voices to the Trash (the library's behavior). Returns how many were removed.
    @discardableResult
    func delete(_ ids: [UUID]) -> Int {
        var n = 0
        for id in ids where (try? library.delete(id)) != nil { n += 1 }
        prune()
        return n
    }
}
