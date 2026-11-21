import Foundation

/// Where the Python interpreter and the `encore_helper` package live.
public struct PythonRuntime: Sendable, Equatable {
    public enum Origin: String, Sendable { case bundled, development, override }

    /// `…/python/bin/python3`
    public var executable: URL
    /// The directory that contains the `encore_helper` package (goes on `PYTHONPATH`).
    public var helperRoot: URL
    public var origin: Origin

    public init(executable: URL, helperRoot: URL, origin: Origin) {
        self.executable = executable; self.helperRoot = helperRoot; self.origin = origin
    }

    /// The runtime home (`…/python`).
    public var home: URL { executable.deletingLastPathComponent().deletingLastPathComponent() }

    public enum Lookup: Sendable, Equatable {
        case found(PythonRuntime)
        /// A developer build without the repo-local runtime: `Scripts/setup-python-runtime.sh` fixes it.
        case needsSetup(String)
        case missing(String)
    }

    /// Finds the runtime: `ENCORE_PYTHON_HOME` (+ optional `ENCORE_HELPER_ROOT`) if set; then the copy inside
    /// the app bundle (`Contents/Resources/python` and `Contents/Resources/PythonHelper`); then, in Debug
    /// builds, the repo-local runtime that `Scripts/setup-python-runtime.sh` creates.
    public static func locate(bundle: Bundle = .main) -> Lookup {
        let fm = FileManager.default
        func runtime(home: URL, helper: URL, origin: Origin) -> PythonRuntime? {
            let python = home.appendingPathComponent("bin/python3")
            guard fm.isExecutableFile(atPath: python.path),
                  fm.fileExists(atPath: helper.appendingPathComponent("encore_helper/__main__.py").path)
            else { return nil }
            return PythonRuntime(executable: python, helperRoot: helper, origin: origin)
        }

        let env = ProcessInfo.processInfo.environment
        if let home = env["ENCORE_PYTHON_HOME"], !home.isEmpty {
            let homeURL = URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
            let helper = env["ENCORE_HELPER_ROOT"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? repoRoot?.appendingPathComponent("PythonHelper") ?? homeURL.deletingLastPathComponent()
            if let r = runtime(home: homeURL, helper: helper, origin: .override) { return .found(r) }
            return .missing("ENCORE_PYTHON_HOME points at \(home), which has no usable Python runtime and helper.")
        }

        if let resources = bundle.resourceURL,
           let r = runtime(home: resources.appendingPathComponent("python"),
                           helper: resources.appendingPathComponent("PythonHelper"), origin: .bundled) {
            return .found(r)
        }

        #if DEBUG
        if let root = repoRoot {
            let helper = root.appendingPathComponent("PythonHelper")
            if let r = runtime(home: helper.appendingPathComponent(".runtime/python"), helper: helper, origin: .development) {
                return .found(r)
            }
            return .needsSetup("The Python runtime isn't set up. In the Encore repository, run Scripts/setup-python-runtime.sh, then try again.")
        }
        #endif
        return .missing("This copy of Encore is missing its Python runtime. Reinstall Encore to use models that run in Python.")
    }

    /// The repository this file was compiled from, if it's still there (developer builds only).
    static var repoRoot: URL? {
        #if DEBUG
        // …/Packages/EncoreCore/Sources/EncoreCore/Engines/Python/PythonRuntime.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("PythonHelper").path) ? url : nil
        #else
        return nil
        #endif
    }

    /// The helper's environment, built from scratch so nothing from the user's shell (PYTHONPATH, a
    /// conda env, …) leaks in. Nothing here points inside the app bundle for writing.
    /// `sharedHubToken: false` (signed out of Encore only) hides the shared token file from huggingface_hub,
    /// which would otherwise read it on its own.
    func environment(ffmpegDirectory: URL?, offline: Bool = true, sharedHubToken: Bool = true) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var pathDirs = [executable.deletingLastPathComponent().path]
        if let ffmpegDirectory { pathDirs.append(ffmpegDirectory.path) }
        // mlx-audio shells out to ffmpeg/ffprobe for MP3/M4A/video; GUI apps don't get the shell's PATH.
        pathDirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var env: [String: String] = [
            "PATH": pathDirs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":"),
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": EncorePaths.scratch.path,
            "LANG": "en_US.UTF-8",
            "PYTHONPATH": helperRoot.path,
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
            "PYTHONUTF8": "1",
            "HF_HOME": EncorePaths.huggingFaceHome.path,
            "HF_HUB_CACHE": EncorePaths.huggingFaceHub.path,
            "HF_TOKEN_PATH": EncorePaths.huggingFaceTokenFile.path,
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
            "TOKENIZERS_PARALLELISM": "false",
            "TRANSFORMERS_NO_ADVISORY_WARNINGS": "1",
        ]
        if offline {
            env["HF_HUB_OFFLINE"] = "1"
            env["TRANSFORMERS_OFFLINE"] = "1"
        }
        if !sharedHubToken {
            // huggingface_hub reads HF_TOKEN_PATH and treats an empty file as no token; /dev/null can't be written to.
            env["HF_TOKEN_PATH"] = "/dev/null"
            env["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        }
        for key in ["USER", "LOGNAME", "SHELL", "__CF_USER_TEXT_ENCODING"] { env[key] = inherited[key] }
        return env.compactMapValues { $0 }
    }
}
