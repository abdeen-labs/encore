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
    /// Things that went wrong while starting (a damaged history database, manifests that didn't decode), for the UI to show.
    let startupProblems: [String]
    /// Long-lived per-screen state; use `screenModel(_:make:)` (Features/Shared/ModelShelf.swift).
    @ObservationIgnored var screenModels: [String: AnyObject] = [:]

    /// Snapshots (`--snapshot`) get throwaway stores in a temporary folder and an empty model cache, so rendering
    /// never touches the user's data, never loads a model and never starts the Python helper.
    init(router: Router = Router(), toasts: ToastCenter = ToastCenter()) {
        self.router = router
        self.toasts = toasts
        let isSnapshot = SnapshotConfig(arguments: CommandLine.arguments) != nil
        let locations = isSnapshot ? Locations.snapshot : Locations.live
        var problems: [String] = []

        let (catalog, manifestProblems) = ModelCatalog.bundled()
        problems += manifestProblems.map { "Model manifest \($0)" }
        self.catalog = catalog

        // Snapshots: a throwaway suite, removed (domain and plist) when the run exits.
        settings = isSnapshot ? AppSettings(defaults: ThrowawayDefaults.make("EncoreSnapshot").defaults) : AppSettings()
        let database: HistoryDatabase
        do {
            database = try HistoryDatabase(directory: locations.history)
        } catch {
            problems.append("History couldn't be opened (\(error.localizedDescription)); this session's history is temporary.")
            database = try! HistoryDatabase(directory: Locations.snapshot.history.appendingPathComponent(UUID().uuidString))
        }
        history = HistoryStore(database: database)
        voices = VoiceLibrary(directory: locations.voices)
        presets = PresetStore(directory: locations.support)
        pronunciations = PronunciationStore(directory: locations.support)

        let hubStore = HubLocalStore(layout: HubCacheLayout(root: locations.hubCache))
        let tokens = isSnapshot ? HubTokenStore.snapshot(in: locations.support) : .standard  // snapshots never read the real token
        hubAccount = HubAccountModel(tokenStore: tokens)
        downloads = ModelDownloadCenter(catalog: catalog, downloader: HubDownloader(service: HubService(tokenStore: tokens), store: hubStore))

        let status = RuntimeStatus()
        runtimeStatus = status
        let settings = self.settings
        let runtime = ModelRuntime(idleMinutes: { settings.snapshot().idleUnloadMinutes }, status: status, autoSweep: !isSnapshot)
        // MLX Swift first; the Python helper covers what Swift can't (voice conversion, word timestamps, …).
        let backends: [any EngineBackend] = isSnapshot ? [] : [MLXSwiftBackend(), PythonBackend()]
        service = EncoreService(catalog: catalog, history: database, voices: voices, pronunciations: pronunciations,
                                settings: settings, hub: hubStore, backends: backends, runtime: runtime,
                                scratchDirectory: locations.scratch)
        startupProblems = problems

        if !isSnapshot { observeIdleSetting() }
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

        static let live = Locations(support: EncorePaths.applicationSupport, history: EncorePaths.history,
                                    voices: EncorePaths.voices, scratch: nil, hubCache: EncorePaths.huggingFaceHub)

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
            return Locations(support: root, history: root.appendingPathComponent("History"), voices: root.appendingPathComponent("Voices"),
                             scratch: root.appendingPathComponent("Scratch"), hubCache: root.appendingPathComponent("hub"))
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
            .environment(deps.settings)
            .environment(deps.history)
            .environment(deps.voices)
            .environment(deps.presets)
            .environment(deps.pronunciations)
            .environment(deps.hubAccount)
            .environment(deps.downloads)
            .environment(deps.runtimeStatus)
            .environment(deps.service)
    }
}
