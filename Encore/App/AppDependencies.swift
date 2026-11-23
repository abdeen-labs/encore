import EncoreCore
import EncoreMLX
import SwiftUI

/// Long-lived app state shared by every screen. The real app and the snapshot renderer both
/// build one of these and inject it with `.appDependencies(_:)`, so anything added here is
/// available in snapshots too. Add your feature's models here.
///
/// Screens declare what they need: `@Environment(EncoreService.self)`, `@Environment(RuntimeStatus.self)`,
/// `@Environment(VoiceLibrary.self)`, `@Environment(HistoryStore.self)`, `@Environment(AppSettings.self)`,
/// `@Environment(ModelDownloadCenter.self)`, … All generation goes through `service`.
@Observable final class AppDependencies {
    let router: Router
    let toasts: ToastCenter
    /// Audio exports in flight, drawn as progress cards (Design/Audio/ExportProgress.swift).
    let exports = ExportProgressCenter()

    let catalog: ModelCatalog
    let settings: AppSettings
    let history: HistoryStore
    let voices: VoiceLibrary
    let presets: PresetStore
    let pronunciations: PronunciationStore
    let hubAccount: HubAccountModel
    let downloads: ModelDownloadCenter
    let runtimeStatus: RuntimeStatus
    let service: EncoreService
    /// The local API and MCP server (Settings → Local API). Never listens in snapshots or isolated runs.
    let localAPI: LocalAPIController
    /// Things that went wrong while starting (a damaged history database, manifests that didn't decode), for the UI to show.
    let startupProblems: [String]
    /// Where screens keep drafts that survive relaunch (`.standard` in the app; nil in snapshots).
    let drafts: UserDefaults?
    /// Settings → Reset → Delete all app data (Features/Settings/ResetActions.swift drives it).
    let appDataReset: AppDataReset
    /// The live app also clears the system-managed URL cache, cookies and web data; isolated runs never do.
    let clearsSystemStorage: Bool
    /// Long-lived per-screen state; use `screenModel(_:make:)` (Features/Shared/ModelShelf.swift).
    @ObservationIgnored var screenModels: [String: AnyObject] = [:]

    /// Snapshots (`--snapshot`) get throwaway stores in a temporary folder and an empty model cache, so rendering
    /// never touches the user's data, never loads a model and never starts the Python helper.
    /// `isolatedRoot` (DEBUG headless proofs) puts every store, the defaults and the Keychain item in throwaway places
    /// under that folder and uses the Hugging Face cache from the environment (`HF_HOME`), which the caller points there.
    init(router: Router = Router(), toasts: ToastCenter = ToastCenter(), isolatedRoot: URL? = nil) {
        self.router = router
        self.toasts = toasts
        let isSnapshot = isolatedRoot == nil && SnapshotConfig(arguments: CommandLine.arguments) != nil
        let isolated = isSnapshot || isolatedRoot != nil
        let locations: Locations = if let isolatedRoot { .isolated(isolatedRoot) } else if isSnapshot { .snapshot } else { .live }
        var problems: [String] = []

        let (catalog, manifestProblems) = ModelCatalog.bundled()
        problems += manifestProblems.map { "Model manifest \($0)" }
        self.catalog = catalog

        // Snapshots and isolated runs: a throwaway suite, removed (domain and plist) when the run exits.
        let (defaults, defaultsDomain) = isolated ? ThrowawayDefaults.make(isSnapshot ? "EncoreSnapshot" : "EncoreIsolated")
                                                  : (UserDefaults.standard, Bundle.main.bundleIdentifier ?? "dev.abdeen.encore")
        settings = AppSettings(defaults: defaults)
        drafts = isSnapshot ? nil : defaults
        clearsSystemStorage = !isolated
        let database: HistoryDatabase
        // Snapshot and isolated runs keep deleted audio in their own temp root, never in the user's Trash.
        let trash: FileTrash = isolated ? .folder(locations.support.deletingLastPathComponent().appendingPathComponent("Trash")) : .system
        do {
            database = try HistoryDatabase(directory: locations.history, trash: trash)
        } catch {
            problems.append("History couldn't be opened (\(error.localizedDescription)); this session's history is temporary.")
            database = try! HistoryDatabase(directory: Locations.snapshot.history.appendingPathComponent(UUID().uuidString), trash: trash)
        }
        history = HistoryStore(database: database)
        voices = VoiceLibrary(directory: locations.voices)
        presets = PresetStore(directory: locations.support)
        pronunciations = PronunciationStore(directory: locations.support)

        let hubStore = HubLocalStore(layout: HubCacheLayout(root: locations.hubCache))
        let tokens: HubTokenStore = if isolatedRoot != nil {
            HubTokenStore(service: HubTokenStore.defaultService + ".isolated-\(UUID().uuidString)",
                          tokenFile: EncorePaths.huggingFaceTokenFile, readsEnvironment: false)
        } else if isSnapshot {
            .snapshot(in: locations.support)  // snapshots never read the real token
        } else {
            .standard
        }
        // Isolated runs never call huggingface.co: whoami goes to a closed local port and reads as "unreachable".
        hubAccount = isolatedRoot == nil ? HubAccountModel(tokenStore: tokens)
            : HubAccountModel(tokenStore: tokens, endpoint: URL(string: "http://127.0.0.1:9")!)
        downloads = ModelDownloadCenter(catalog: catalog, downloader: HubDownloader(service: HubService(tokenStore: tokens), store: hubStore))

        let status = RuntimeStatus()
        runtimeStatus = status
        let settings = self.settings
        let runtime = ModelRuntime(idleMinutes: { settings.snapshot().idleUnloadMinutes }, status: status, autoSweep: !isolated)
        // MLX Swift first; the Python helper covers what Swift can't (voice conversion, word timestamps, …).
        // The helper isn't shown the shared HF token file while the user is signed out of Encore only.
        let backends: [any EngineBackend] = isSnapshot ? [] : [MLXSwiftBackend(),
            PythonBackend(configuration: .init(usesSharedHubToken: { !tokens.isSignedOutOfEncoreOnly }))]
        service = EncoreService(catalog: catalog, history: database, voices: voices, pronunciations: pronunciations,
                                settings: settings, hub: hubStore, backends: backends, runtime: runtime,
                                scratchDirectory: locations.scratch)
        localAPI = LocalAPIController(service: service, settings: settings, isLive: !isolated)
        startupProblems = problems
        appDataReset = AppDataReset(history: database, voices: voices, presets: presets, pronunciations: pronunciations,
                                    settings: settings, defaults: defaults, defaultsDomain: defaultsDomain, tokenStore: tokens,
                                    locations: .init(applicationSupport: locations.support,
                                                     scratch: [locations.scratch ?? EncorePaths.scratch, service.scratchDirectory],
                                                     caches: locations.caches, keep: Locations.systemOwnedCacheFiles))

        if !isolated { observeIdleSetting() }
    }

    /// The idle-unload timer re-reads the setting on its own within 30 s; this makes a change take effect at once.
    private func observeIdleSetting() {
        withObservationTracking { _ = settings.idleUnloadMinutes } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.service.runtime.settingsChanged()
                self.observeIdleSetting()
            }
        }
    }

    private struct Locations {
        var support: URL
        var history: URL
        var voices: URL
        var scratch: URL?
        var hubCache: URL
        /// Cleared by Delete all app data.
        var caches: [URL] = []

        static var live: Locations {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let id = Bundle.main.bundleIdentifier ?? "dev.abdeen.encore"
            return Locations(support: EncorePaths.applicationSupport, history: EncorePaths.history,
                             voices: EncorePaths.voices, scratch: nil, hubCache: EncorePaths.huggingFaceHub,
                             caches: [library.appendingPathComponent("Caches/\(id)"),
                                      library.appendingPathComponent("HTTPStorages/\(id)"),
                                      library.appendingPathComponent("HTTPStorages/\(id).binarycookies")])
        }

        /// Databases the system keeps open in those cache folders; emptied through URLCache and cookie storage instead.
        static let systemOwnedCacheFiles: Set<String> = ["Cache.db", "Cache.db-wal", "Cache.db-shm",
                                                          "httpstorages.sqlite", "httpstorages.sqlite-wal", "httpstorages.sqlite-shm"]

        /// Everything in a throwaway folder (`root/Support`, `root/Scratch`, `root/Caches`); the model cache is
        /// whatever `HF_HOME` / `HF_HUB_CACHE` say, which the headless proofs point inside `root`.
        static func isolated(_ root: URL) -> Locations {
            let support = root.appendingPathComponent("Support")
            return Locations(support: support, history: support.appendingPathComponent("History"),
                             voices: support.appendingPathComponent("Voices"), scratch: root.appendingPathComponent("Scratch"),
                             hubCache: EncorePaths.huggingFaceHub, caches: [root.appendingPathComponent("Caches")])
        }

        /// One temporary root per process, shared by every snapshot target.
        static let snapshot: Locations = {
            let fm = FileManager.default
            // Clear out roots left by earlier snapshot runs (an hour old or more; a concurrent run keeps its own).
            let hourAgo = Date().addingTimeInterval(-3600)
            for old in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where old.lastPathComponent.hasPrefix("EncoreSnapshot-")
                && ((try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < hourAgo {
                try? fm.removeItem(at: old)
            }
            let root = fm.temporaryDirectory
                .appendingPathComponent("EncoreSnapshot-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            let support = root.appendingPathComponent("Support")
            return Locations(support: support, history: support.appendingPathComponent("History"),
                             voices: support.appendingPathComponent("Voices"), scratch: root.appendingPathComponent("Scratch"),
                             hubCache: root.appendingPathComponent("hub"), caches: [root.appendingPathComponent("Caches")])
        }()
    }
}

extension View {
    /// Injects every shared dependency into the environment.
    func appDependencies(_ deps: AppDependencies) -> some View {
        self
            .environment(deps)
            .environment(deps.router)
            .environment(deps.toasts)
            .environment(deps.exports)
            .environment(deps.settings)
            .environment(deps.history)
            .environment(deps.voices)
            .environment(deps.presets)
            .environment(deps.pronunciations)
            .environment(deps.hubAccount)
            .environment(deps.downloads)
            .environment(deps.runtimeStatus)
            .environment(deps.service)
            .environment(deps.localAPI)
    }
}
