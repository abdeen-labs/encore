import Foundation
import Observation
import Synchronization

/// Saved generation settings, per model. Stored as `<directory>/presets.json`.
/// Threading: see StoreSupport.swift. `preset(_:)` is callable from any isolation.
@MainActor @Observable
public final class PresetStore {
    /// All presets, in the order they were created.
    public private(set) var presets: [Preset] = []
    /// Set when the file existed but couldn't be read (it is kept aside, not overwritten).
    public private(set) var loadError: String?

    @ObservationIgnored public nonisolated let fileURL: URL
    @ObservationIgnored private nonisolated let snapshot = Mutex<[Preset]>([])

    public init(directory: URL = EncorePaths.applicationSupport) {
        fileURL = directory.appendingPathComponent("presets.json")
        do {
            presets = try StoreFiles.read([Preset].self, from: fileURL) ?? []
        } catch {
            loadError = "Saved presets couldn't be read: \(error.localizedDescription)"
            StoreFiles.quarantine(fileURL)
        }
        snapshot.withLock { $0 = presets }
    }

    /// A model's presets, by name.
    public func presets(for modelID: String) -> [Preset] {
        presets.filter { $0.modelID == modelID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public nonisolated func preset(_ id: UUID) -> Preset? { snapshot.withLock { $0.first { $0.id == id } } }

    /// Adds a preset, or replaces the one with the same id.
    public func save(_ preset: Preset) throws {
        var p = preset
        p.name = p.name.trimmed()
        var all = presets
        if let i = all.firstIndex(where: { $0.id == p.id }) { all[i] = p } else { all.append(p) }
        try commit(all)
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard var p = presets.first(where: { $0.id == id }) else { throw StoreError.notFound("The preset") }
        p.name = name
        try save(p)
    }

    public func delete(_ id: UUID) throws { try commit(presets.filter { $0.id != id }) }

    private func commit(_ all: [Preset]) throws {
        try StoreFiles.write(all, to: fileURL)
        presets = all
        snapshot.withLock { $0 = all }
        loadError = nil
    }
}
