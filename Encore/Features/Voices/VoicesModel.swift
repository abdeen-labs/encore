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

    let library: VoiceLibrary

    var query = ""
    var tags: Set<String> = []
    var origin: OriginFilter = .all
    var sort: Sort = .newest
    /// Voices ticked for bulk actions.
    var selection: Set<UUID> = []
    /// The voice open in the inspector.
    var focused: UUID?
    var importReport: ImportReport?
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
    }

    /// Click on a card: plain selects one and opens it; ⌘ toggles; ⇧ extends from the last click.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags, in list: [Voice]) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            focused = selection.count == 1 ? selection.first : (selection.contains(id) ? id : focused.flatMap { selection.contains($0) ? $0 : nil })
            anchor = id
        } else if modifiers.contains(.shift), let a = anchor, let i = list.firstIndex(where: { $0.id == a }),
                  let j = list.firstIndex(where: { $0.id == id }) {
            selection.formUnion(list[min(i, j)...max(i, j)].map(\.id))
            focused = id
        } else {
            focus(id)
        }
    }

    func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        if selection.count != 1 { focused = selection.contains(focused ?? UUID()) ? focused : nil }
        anchor = id
    }

    /// Drops selected/focused ids that no longer exist.
    func prune() {
        let ids = Set(library.voices.map(\.id))
        selection.formIntersection(ids)
        if let f = focused, !ids.contains(f) { focused = nil }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async {
        let files = urls.filter { $0.pathExtension.lowercased() == VoiceLibrary.fileExtension }
        guard !files.isEmpty else { return }
        busy = files.count == 1 ? "Importing \(files[0].lastPathComponent)…" : "Importing \(files.count) files…"
        defer { busy = nil }
        var report = ImportReport(imported: [], refused: [])
        for url in files {
            do {
                report.imported += try await library.importVoices(from: url)
            } catch {
                report.refused.append(.init(file: url.lastPathComponent, reason: Self.describe(error)))
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
