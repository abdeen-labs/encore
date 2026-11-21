import Foundation

/// Locates and runs the user's ffmpeg. Encore doesn't bundle one; it's needed for MP3 export and for
/// containers AVFoundation can't open (mkv, webm, ogg, …).
public enum FFmpeg {
    /// UserDefaults key holding a user-chosen path to the ffmpeg binary (or the folder containing it).
    public static let userPathDefaultsKey = "ffmpegPath"

    /// Search order: explicit path, the user-configured path, Homebrew (Apple Silicon), Homebrew (Intel) /
    /// MacPorts-style `/usr/local/bin`, `/opt/local/bin`, then every directory on `PATH`.
    public static func locate(configuredPath: String? = nil) -> URL? {
        locate(tool: "ffmpeg", configuredPath: configuredPath)
    }

    /// ffprobe, looked up next to ffmpeg first.
    public static func locateProbe(configuredPath: String? = nil) -> URL? {
        if let ffmpeg = locate(configuredPath: configuredPath) {
            let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if isExecutable(sibling) { return sibling }
        }
        return locate(tool: "ffprobe", configuredPath: nil)
    }

    public static var isAvailable: Bool { locate() != nil }

    /// Throws `AudioError.ffmpegMissing` with a message that says what to do.
    public static func require(for purpose: String) throws -> URL {
        guard let url = locate() else { throw AudioError.ffmpegMissing(purpose: purpose) }
        return url
    }

    static func locate(tool: String, configuredPath: String?) -> URL? {
        var candidates: [String] = []
        let userPath = configuredPath ?? UserDefaults.standard.string(forKey: userPathDefaultsKey)
        if let userPath, !userPath.isEmpty {
            let expanded = (userPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                candidates.append((expanded as NSString).appendingPathComponent(tool))
            } else if tool == "ffmpeg" {
                candidates.append(expanded)
            } else {
                candidates.append(((expanded as NSString).deletingLastPathComponent as NSString).appendingPathComponent(tool))
            }
        }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].map { "\($0)/\(tool)" }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/\(tool)" }
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate)
            if isExecutable(url) { return url }
        }
        return nil
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// The encoding position in seconds from one line of ffmpeg's `-progress` output (`out_time_us=…`, or the
    /// older, misnamed `out_time_ms=…`, both microseconds). Nil for any other line or an `N/A` value.
    static func progressSeconds(_ line: String) -> Double? {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[0] == "out_time_us" || parts[0] == "out_time_ms",
              let micros = Double(parts[1].trimmingCharacters(in: .whitespaces)), micros >= 0 else { return nil }
        return micros / 1_000_000
    }

    /// Runs a tool to completion, returning stdout. Stderr is collected for error messages.
    /// Canceling the calling task terminates the process.
    /// - Parameter onStdoutLine: called with each complete stdout line as it arrives (on a background thread).
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String],
                    onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onStdoutLine)
        out.fileHandleForReading.readabilityHandler = { h in collector.appendOut(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in collector.appendErr(h.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
        collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()
        guard status == 0 else {
            throw AudioError.ffmpegFailed(status: status, message: collector.errorTail)
        }
        return collector.out
    }

    final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _out = Data(), _err = Data()
        private let onLine: (@Sendable (String) -> Void)?
        /// Bytes of stdout after the last newline handed to `onLine`.
        private var pending = Data()

        init(onLine: (@Sendable (String) -> Void)? = nil) { self.onLine = onLine }

        func appendOut(_ d: Data) {
            guard !d.isEmpty else { return }
            let lines: [String] = lock.withLock {
                _out.append(d)
                guard onLine != nil else { return [] }
                pending.append(d)
                guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
                let complete = pending[pending.startIndex...last]
                pending = Data(pending[pending.index(after: last)...])
                return String(decoding: complete, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            }
            if let onLine { lines.forEach(onLine) }
        }
        func appendErr(_ d: Data) { lock.withLock { _err.append(d) } }
        var out: Data { lock.withLock { _out } }
        /// Last few meaningful stderr lines.
        var errorTail: String {
            let text = String(decoding: lock.withLock { _err }, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            return lines.suffix(3).joined(separator: " — ")
        }
    }
}
