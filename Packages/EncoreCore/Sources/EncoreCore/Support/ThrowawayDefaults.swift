import Foundation

/// `UserDefaults` that never touch `~/Library/Preferences`. A named suite (`UserDefaults(suiteName: "x")`) makes
/// cfprefsd write `~/Library/Preferences/x.plist`, and removing the domain afterwards still leaves an empty plist
/// behind (cfprefsd rewrites it after the process lets go). CFPreferences also accepts an absolute path as the
/// domain, so these suites live as a plist inside a folder of our choosing, which is simply deleted.
///
///     let scratch = ThrowawayDefaults.make("EncoreSnapshot")      // temp folder, removed at exit
///     let defaults = ThrowawayDefaults.defaults(in: tempDir.url)   // lives and dies with tempDir
public enum ThrowawayDefaults {
    nonisolated(unsafe) private static var pending: Set<String> = []
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    /// Defaults stored in `<directory>/defaults.plist`. The directory is created if needed; deleting it deletes them.
    public static func defaults(in directory: URL) -> UserDefaults {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return UserDefaults(suiteName: suitePath(in: directory))!
    }

    /// Defaults in a fresh temporary folder (`<tmp>/<prefix>-<pid>-<random>/`), deleted when the process exits.
    /// `suite` is what to pass to `remove(_:)` to delete them earlier.
    public static func make(_ prefix: String) -> (defaults: UserDefaults, suite: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let defaults = defaults(in: dir)
        let suite = suitePath(in: dir)
        removeAtExit(suite)
        return (defaults, suite)
    }

    /// Flushes and deletes a suite made by `make(_:)` (its folder goes with it).
    public static func remove(_ suite: String) {
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: suite).deletingLastPathComponent())
        lock.withLock { _ = pending.remove(suite) }
    }

    static func suitePath(in directory: URL) -> String { directory.appendingPathComponent("defaults").path }

    private static func removeAtExit(_ suite: String) {
        let install = lock.withLock { () -> Bool in
            pending.insert(suite)
            defer { installed = true }
            return !installed
        }
        if install {
            atexit {
                for s in ThrowawayDefaults.lock.withLock({ ThrowawayDefaults.pending }) { ThrowawayDefaults.remove(s) }
            }
        }
    }
}
