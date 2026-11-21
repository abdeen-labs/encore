// App updates, through Sparkle. It checks the appcast at Info.plist's SUFeedURL in the background, verifies the
// appcast (SURequireSignedFeed) and each update before unpacking it (SUVerifyUpdateBeforeExtraction) against
// Info.plist's SUPublicEDKey, and shows its own windows. Encore ▸ Check for Updates… checks now.

import Foundation
import Observation
import Sparkle

/// Sparkle's updater, for the app's lifetime. It starts once the main window has appeared (`start()`), and only in
/// Release builds: Debug builds share the released app's bundle identifier, and Sparkle would offer to replace them.
@MainActor @Observable
public final class Updater {
    /// Whether Check for Updates… can run now: false while a check or an update is under way, before the updater
    /// starts, and in Debug builds.
    public private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var isStarted = false

    public init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Starts the updater, once; the main window calls it as it appears. Sparkle may open a window as soon as it
    /// starts (asking whether to check automatically). Started before the main window exists, that window would be
    /// the app's only one.
    public func start() {
        #if !DEBUG
        guard !isStarted else { return }
        isStarted = true
        controller.startUpdater()
        #endif
    }

    /// Checks for an update now, with Sparkle's windows.
    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
