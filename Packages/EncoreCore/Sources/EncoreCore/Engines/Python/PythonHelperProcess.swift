import Foundation
import os

/// One running `python -m encore_helper`: pipes, a reader thread per output stream, and a tail of stderr
/// for error messages. Protocol messages arrive on `output` in order, followed by `.exited`.
final class PythonHelperProcess: @unchecked Sendable {
    enum Output: Sendable {
        case line(Data)
        case exited(status: Int32, signaled: Bool)
    }

    let output: AsyncStream<Output>
    private let process = Process()
    private let stdinHandle: FileHandle
    private let lock = NSLock()
    private var stderrTail: [String] = []
    private static let log = Logger(subsystem: "Encore", category: "python-helper")

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(runtime: PythonRuntime, environment: [String: String]) throws {
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.executableURL = runtime.executable
        // -s: no user site-packages; -B: never write .pyc (the bundle is read-only and signed).
        process.arguments = ["-s", "-B", "-m", "encore_helper"]
        process.environment = environment
        process.currentDirectoryURL = EncorePaths.scratch
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdinHandle = stdinPipe.fileHandleForWriting
        // Writing to a dead helper must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)

        var continuation: AsyncStream<Output>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        let sink = continuation!

        try process.run()
        PythonHelperRegistry.shared.add(process)

        let stdout = stdoutPipe.fileHandleForReading
        let process = self.process
        Thread.detachNewThread {
            Self.readLines(stdout) { sink.yield(.line($0)) }
            process.waitUntilExit()
            PythonHelperRegistry.shared.remove(process)
            sink.yield(.exited(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal))
            sink.finish()
        }
        let stderr = stderrPipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            Self.readLines(stderr) { data in
                let text = String(decoding: data, as: UTF8.self)
                Self.log.debug("\(text, privacy: .public)")
                if ProcessInfo.processInfo.environment["ENCORE_PYTHON_STDERR"] == "1" {
                    FileHandle.standardError.write(data + Data([0x0A]))
                }
                self?.appendStderr(text)
            }
        }
    }

    private static func readLines(_ handle: FileHandle, _ emit: (Data) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { emit(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { emit(buffer) }
    }

    private func appendStderr(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        stderrTail.append(line)
        if stderrTail.count > 60 { stderrTail.removeFirst(stderrTail.count - 60) }
    }

    /// The last few stderr lines, for error messages after a crash.
    func recentStderr(_ count: Int = 6) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(stderrTail.suffix(count))
    }

    func send(_ message: Data) throws {
        var line = message
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)
    }

    /// Closes stdin (the helper exits on EOF), then escalates to SIGTERM and SIGKILL if it lingers.
    func stop(grace: TimeInterval = 2) {
        try? stdinHandle.close()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

/// Every live helper process, so they can be killed synchronously when the app terminates or the
/// harness exits. (If the app is killed outright, the helper sees EOF on stdin and exits by itself.)
final class PythonHelperRegistry: @unchecked Sendable {
    static let shared = PythonHelperRegistry()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil
        ) { _ in PythonHelperRegistry.shared.killAll() }
        atexit { PythonHelperRegistry.shared.killAll() }
    }

    func add(_ p: Process) { lock.lock(); processes[ObjectIdentifier(p)] = p; lock.unlock() }
    func remove(_ p: Process) { lock.lock(); processes[ObjectIdentifier(p)] = nil; lock.unlock() }

    func killAll() {
        lock.lock(); let all = Array(processes.values); lock.unlock()
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}
