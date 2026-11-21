import EncoreCore
import SwiftUI
import WebKit

/// Settings → Reset. The deleting itself is EncoreCore's (`AppDataReset`, `ModelDownloadCenter.removeAllCatalogModels`);
/// this stops what's running first and brings the running app's state back in line afterwards, so nothing on screen
/// shows a take, voice or model that no longer exists.
extension AppDependencies {
    /// Why a reset didn't start.
    enum ResetBlocked: Error, LocalizedError {
        case stillRunning
        var errorDescription: String? {
            "A job didn't stop in time, so nothing was deleted. Wait for it to finish (or cancel it from the rail) and try again."
        }
    }

    /// Stops everything that could be writing or holding files: every job (running or queued), playback, loaded
    /// models and the Python helper. Throws, having deleted nothing, if a job is still running after `timeout`.
    func stopEverythingForReset(timeout: Duration = .seconds(20)) async throws {
        JobRunner.cancelAll()
        NowPlaying.shared.dismiss()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await service.runtime.snapshot().jobs.isEmpty) {
            guard clock.now < deadline else { throw ResetBlocked.stillRunning }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await service.runtime.unloadAll()
        for case let python as PythonBackend in service.backends { await python.shutdown() }
    }

    /// Settings → Delete all app data. Afterwards the app is in its first-launch state, in place: the stores are empty
    /// (their observers update), every screen's kept state is dropped (screens start fresh the next time they open),
    /// and settings are back to their defaults. Models and the shared token file stay.
    func resetAppData() async throws -> AppDataReset.Report {
        try await stopEverythingForReset()
        // Drop every screen's state before the defaults go, so no screen writes its draft back afterwards.
        // The model shelf only mirrors the model cache, which this doesn't touch.
        screenModels = screenModels.filter { $0.key == Self.modelShelfKey }
        if clearsSystemStorage {
            URLCache.shared.removeAllCachedResponses()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            // The Hugging Face pages opened for gated models (sign-in cookies, site data).
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        let report = await appDataReset.run()
        history.query = HistoryQuery()
        // Runtime preferences went back to automatic.
        Task { await modelShelf.refreshRuntimes(for: catalog.models) }
        await hubAccount.refresh()
        return report
    }

    /// Settings → Delete all downloaded models: every repo in Encore's catalog that is in the Hugging Face cache,
    /// partial downloads and mlx-audio working copies included. Nothing outside the catalog is touched.
    func removeAllModels() async throws -> HubRemovalResult {
        await downloads.cancelAllDownloads()
        try await stopEverythingForReset()
        let result = await downloads.removeAllCatalogModels()
        modelShelf.rescan()
        await modelShelf.waitForScan()
        return result
    }

    static let modelShelfKey = "Shared.ModelShelf"
}
