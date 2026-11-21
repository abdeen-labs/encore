import Foundation

/// Where Encore keeps things on disk.
public enum EncorePaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Encore", isDirectory: true))
    }
    public static var history: URL { ensure(applicationSupport.appendingPathComponent("History", isDirectory: true)) }
    public static var voices: URL { ensure(applicationSupport.appendingPathComponent("Voices", isDirectory: true)) }
    public static var scratch: URL {
        ensure(FileManager.default.temporaryDirectory.appendingPathComponent("Encore", isDirectory: true))
    }

    /// `HF_HOME`, defaulting to `~/.cache/huggingface` — the same rule huggingface_hub uses.
    public static var huggingFaceHome: URL {
        let env = ProcessInfo.processInfo.environment
        if let home = env["HF_HOME"], !home.isEmpty { return URL(fileURLWithPath: (home as NSString).expandingTildeInPath) }
        if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appendingPathComponent("huggingface")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface")
    }
    public static var huggingFaceHub: URL {
        if let cache = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !cache.isEmpty {
            return URL(fileURLWithPath: (cache as NSString).expandingTildeInPath)
        }
        return huggingFaceHome.appendingPathComponent("hub")
    }
    public static var huggingFaceTokenFile: URL {
        if let path = ProcessInfo.processInfo.environment["HF_TOKEN_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return huggingFaceHome.appendingPathComponent("token")
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
