import Foundation

/// Deletes everything Encore keeps about the user, so the app is back where it was on first launch, without touching
/// downloaded models or the shared Hugging Face token file:
///
/// - the history database's items and every audio master in its `Audio/` folder,
/// - every voice in the library, permanently (not to the Trash),
/// - presets and the pronunciation list,
/// - anything else in the application-support folder (damaged files kept aside, leftovers),
/// - the settings and every remembered choice and draft: the whole `UserDefaults` domain,
/// - scratch folders and caches,
/// - Encore's Keychain copy of the Hugging Face token.
///
/// The stores are cleared through their own methods, so every observer (SwiftUI, the service) sees them empty at once,
/// and they stay usable. The caller stops jobs, playback and engines first (see the app's Settings screen).
@MainActor
public final class AppDataReset {
    /// The folders the reset clears. The live app passes the real ones; tests and the headless proof pass temp folders.
    public struct Locations: Sendable {
        /// Encore's application-support folder; everything in it except the history and voice folders is removed
        /// (those two are emptied through their stores).
        public var applicationSupport: URL
        /// Folders whose contents are removed (the scratch folder, the service's unsaved renders, …).
        public var scratch: [URL]
        /// Cache folders (emptied, except entries named in `keep`) and files (removed).
        public var caches: [URL]
        public var keep: Set<String>

        public init(applicationSupport: URL, scratch: [URL], caches: [URL] = [], keep: Set<String> = []) {
            self.applicationSupport = applicationSupport; self.scratch = scratch; self.caches = caches; self.keep = keep
        }
    }

    /// What there is to lose, counted when asked.
    public struct Inventory: Sendable, Equatable {
        public var voices = 0
        public var clonedVoices = 0
        public var designedVoices = 0
        public var importedVoices = 0
        public var historyItems = 0
        public var presets = 0
        public var pronunciations = 0
        /// Bytes on disk: history (database and audio), voices, and the rest (scratch, caches, leftovers).
        public var historyBytes: Int64 = 0
        public var voiceBytes: Int64 = 0
        public var otherBytes: Int64 = 0
        public var hasKeychainToken = false
        /// Keys in the defaults domain (settings, remembered choices, drafts, window positions).
        public var settingsKeys = 0
        public var totalBytes: Int64 { historyBytes + voiceBytes + otherBytes }

        public init() {}
    }

    public struct Report: Sendable, Equatable {
        /// What was there just before the reset.
        public var removed: Inventory
        /// Bytes on disk before less bytes after.
        public var bytesFreed: Int64
        /// One line per thing that couldn't be removed. Everything else was removed regardless.
        public var failures: [String]
        public var succeeded: Bool { failures.isEmpty }

        public init(removed: Inventory, bytesFreed: Int64, failures: [String]) {
            self.removed = removed; self.bytesFreed = bytesFreed; self.failures = failures
        }
    }

    public let history: HistoryDatabase
    public let voices: VoiceLibrary
    public let presets: PresetStore
    public let pronunciations: PronunciationStore
    public let settings: AppSettings
    public let defaults: UserDefaults
    /// The persistent domain to remove: the bundle id for `.standard`, the suite name for a `UserDefaults(suiteName:)`.
    public let defaultsDomain: String
    public let tokenStore: HubTokenStore
    public let locations: Locations

    public init(history: HistoryDatabase, voices: VoiceLibrary, presets: PresetStore, pronunciations: PronunciationStore,
                settings: AppSettings, defaults: UserDefaults, defaultsDomain: String, tokenStore: HubTokenStore,
                locations: Locations) {
        self.history = history; self.voices = voices; self.presets = presets; self.pronunciations = pronunciations
        self.settings = settings; self.defaults = defaults; self.defaultsDomain = defaultsDomain
        self.tokenStore = tokenStore; self.locations = locations
    }

    // MARK: Counting

    public func inventory() async -> Inventory {
        var i = Inventory()
        i.voices = voices.voices.count
        i.clonedVoices = voices.voices.filter { $0.origin == .cloned }.count
        i.designedVoices = voices.voices.filter { $0.origin == .designed }.count
        i.importedVoices = voices.voices.filter { $0.origin == .imported }.count
        i.historyItems = (try? await history.count()) ?? 0
        i.presets = presets.presets.count
        i.pronunciations = pronunciations.entries.count
        i.settingsKeys = defaults.persistentDomain(forName: defaultsDomain)?.count ?? 0
        let store = tokenStore
        i.hasKeychainToken = await Task.detached { store.hasKeychainToken }.value
        let (h, v, o) = await measure()
        i.historyBytes = h; i.voiceBytes = v; i.otherBytes = o
        return i
    }

    /// Bytes in the history folder, the voice folder, and everything else the reset clears.
    private func measure() async -> (Int64, Int64, Int64) {
        let historyDir = history.directory, voiceDir = voices.directory, l = locations
        return await Task.detached(priority: .userInitiated) {
            let others = Self.supportLeftovers(l.applicationSupport, protecting: [historyDir, voiceDir])
                + l.scratch.flatMap { Self.contents($0) } + l.caches
            return (Self.size(historyDir), Self.size(voiceDir), others.reduce(0) { $0 + Self.size($1) })
        }.value
    }

    // MARK: Resetting

    /// Clears everything listed in the type's description. Never throws: whatever can't be removed is reported in
    /// `failures` and everything else is removed anyway. Safe to run again (a second run finds nothing).
    public func run() async -> Report {
        let before = await inventory()
        var failures: [String] = []
        let fm = FileManager.default

        // Settings first, so nothing in memory writes old values back after the domain is gone.
        settings.resetToDefaults()

        do {
            failures += try await history.deleteAll().failures
        } catch {
            failures.append("History: \(error.localizedDescription)")
        }
        failures += voices.deleteAllPermanently().failures
        do { try presets.deleteAll() } catch { failures.append("Presets: \(error.localizedDescription)") }
        do { try pronunciations.deleteAll() } catch { failures.append("Pronunciations: \(error.localizedDescription)") }

        for item in Self.supportLeftovers(locations.applicationSupport, protecting: [history.directory, voices.directory]) {
            do { try fm.removeItem(at: item) } catch { failures.append("\(item.path): \(error.localizedDescription)") }
        }
        for folder in locations.scratch {
            for item in Self.contents(folder) {
                do { try fm.removeItem(at: item) } catch { failures.append("\(item.path): \(error.localizedDescription)") }
            }
        }
        for item in locations.caches {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            // A folder is emptied except for the names in `keep` (an open database the system owns); a file goes.
            let doomed = isDirectory.boolValue ? Self.contents(item).filter { !locations.keep.contains($0.lastPathComponent) } : [item]
            for entry in doomed {
                do { try fm.removeItem(at: entry) } catch { failures.append("\(entry.path): \(error.localizedDescription)") }
            }
        }

        defaults.removePersistentDomain(forName: defaultsDomain)
        if let left = defaults.persistentDomain(forName: defaultsDomain), !left.isEmpty {
            failures.append("Settings: \(left.count) values couldn't be removed")
        }

        do { try tokenStore.removeKeychainToken() } catch { failures.append("Keychain: \(error.localizedDescription)") }
        // Back to a first launch: an Encore-only sign-out is forgotten too, so the shared token file is used again.
        do { try tokenStore.clearEncoreOnlySignOut() } catch { failures.append("Keychain: \(error.localizedDescription)") }

        let after = await inventory()
        return Report(removed: before, bytesFreed: max(0, before.totalBytes - after.totalBytes), failures: failures)
    }

    // MARK: Files

    /// Everything in the support folder except the history and voice folders (emptied by their stores).
    nonisolated static func supportLeftovers(_ support: URL, protecting kept: [URL]) -> [URL] {
        let keep = Set(kept.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        return contents(support).filter { !keep.contains($0.standardizedFileURL.resolvingSymlinksInPath().path) }
    }

    nonisolated static func contents(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Allocated bytes of a file or of every regular file under a folder (links aren't followed).
    nonisolated static func size(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? 0) }
        guard v.isDirectory == true, let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let f = try? file.resourceValues(forKeys: keys)
            if f?.isRegularFile == true { total += Int64(f?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
