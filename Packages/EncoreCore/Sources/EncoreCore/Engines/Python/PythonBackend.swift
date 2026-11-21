import Foundation
import os

/// Runs models in the bundled Python helper (mlx-audio) — voice conversion, Whisper word timestamps,
/// and any model the user prefers to run there.
///
/// The helper starts on first use and stops after `idleShutdown` with nothing to do (which frees every
/// model it held). Models the app loaded are remembered, so after an idle stop or a crash the next job
/// reloads its model transparently. Cancelling the calling task cancels the helper's job; if the helper
/// doesn't stop within `cancelGrace`, it's killed and restarted on next use.
public actor PythonBackend: EngineBackend {
    public struct Configuration: Sendable {
        /// Stop the helper process after this long without work.
        public var idleShutdown: TimeInterval = 300
        /// How long a cancelled job may take to stop before the helper is killed.
        public var cancelGrace: TimeInterval = 15
        /// Directory holding the user's ffmpeg/ffprobe, when Encore found them somewhere unusual.
        public var ffmpegDirectory: URL?
        /// Use this runtime instead of looking one up.
        public var runtime: PythonRuntime?
        public init() {}
    }

    /// What the helper said about itself at startup.
    public struct Handshake: Sendable {
        public var protocolVersion: Int
        public var helperVersion: String
        public var pythonVersion: String
        public var packages: [String: String]
        public var engines: [String: EngineFeatures]
        /// Engine key → why this install can't run it.
        public var unavailable: [String: String]
    }

    public struct MemoryStats: Sendable {
        /// MLX bytes in use, in MLX's buffer cache, and the MLX peak since the helper started.
        public var active: Int64, cache: Int64, peak: Int64
        /// The helper's peak resident size.
        public var peakResident: Int64
    }

    public nonisolated let runtime: EngineRuntime = .python
    private let configuration: Configuration
    private static let log = Logger(subsystem: "Encore", category: "python-backend")

    private var helper: PythonHelperProcess?
    private var generation = 0
    private var startTask: Task<Handshake, Error>?
    private var handshake: Handshake?
    private var stopping: Set<Int> = []  // generations we stopped on purpose
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var cancelledIDs: Set<Int> = []
    private var contexts: [String: ModelLoadContext] = [:]
    private var resident: Set<String> = []
    private var idleTask: Task<Void, Never>?
    private var lastFailure: String?

    private struct Pending {
        var continuation: CheckedContinuation<Data, Error>
        var progress: EngineProgress?
        var generation: Int
        var op: String
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: EngineBackend

    public func availability() async -> BackendAvailability {
        switch locateRuntime() {
        case .found:
            if let lastFailure, handshake == nil { return .unavailable(lastFailure) }
            return .ready
        case .needsSetup(let message): return .needsSetup(message)
        case .missing(let message): return .unavailable(message)
        }
    }

    public func engineFeatures() async -> [String: EngineFeatures] {
        if let handshake { return handshake.engines }
        guard case .found = locateRuntime() else { return [:] }
        return (try? await ensureStarted().engines) ?? [:]
    }

    public func load(_ context: ModelLoadContext) async throws {
        let info = try await ensureStarted()
        let engine = context.manifest.engine
        guard info.engines[engine] != nil else {
            throw EngineError.unsupported(info.unavailable[engine]
                ?? "The Python helper can't run \(context.manifest.name) (engine “\(engine)”).")
        }
        contexts[context.manifest.id] = context
        try await sendLoad(context)
    }

    public func unload(modelID: String) async {
        contexts[modelID] = nil
        guard resident.contains(modelID), helper != nil else { return }
        resident.remove(modelID)
        _ = try? await call("unload", ["model_id": modelID])
    }

    public func loadedModelIDs() async -> [String] { resident.sorted() }

    public func synthesize(_ job: SynthesisJob, progress: EngineProgress?) async throws -> AudioBuffer {
        try await ensureResident(job.modelID)
        let output = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: output) }
        var payload: [String: Any] = [
            "model_id": job.modelID, "text": job.text, "output_path": output.path,
            "params": job.parameters.mapValues(\.jsonObject),
        ]
        if let voice = job.voice { payload["voice"] = Self.voicePayload(voice) }
        if let instruct = job.instruct { payload["instruct"] = instruct }
        if let language = job.language { payload["language"] = language }
        let result = try await call("synthesize", payload, progress: progress)
        Self.logIgnored(result, job.modelID)
        return try PythonWAV.read(output)
    }

    public func transcribe(_ job: TranscriptionJob, progress: EngineProgress?) async throws -> Transcript {
        try await ensureResident(job.modelID)
        var payload: [String: Any] = [
            "model_id": job.modelID, "audio_path": job.audio.path, "timestamps": job.timestamps.rawValue,
            "params": job.parameters.mapValues(\.jsonObject),
        ]
        if let language = job.language { payload["language"] = language }
        let result = try await call("transcribe", payload, progress: progress)
        Self.logIgnored(result, job.modelID)
        do {
            return try JSONDecoder().decode(Transcript.self, from: JSONSerialization.data(withJSONObject: result))
        } catch {
            throw EngineError.failed("The Python helper returned a transcript Encore couldn't read: \(error.localizedDescription)")
        }
    }

    public func convertVoice(_ job: VoiceConversionJob, progress: EngineProgress?) async throws -> AudioBuffer {
        guard job.target.referenceAudio != nil else {
            throw EngineError.unsupported("Voice conversion needs a target voice with reference audio.")
        }
        try await ensureResident(job.modelID)
        let output = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: output) }
        let payload: [String: Any] = [
            "model_id": job.modelID, "source_path": job.source.path, "output_path": output.path,
            "target": Self.voicePayload(job.target), "params": job.parameters.mapValues(\.jsonObject),
        ]
        let result = try await call("convert_voice", payload, progress: progress)
        Self.logIgnored(result, job.modelID)
        return try PythonWAV.read(output)
    }

    // MARK: Extras for the app and the harness

    /// Starts the helper if needed and returns its handshake.
    @discardableResult
    public func start() async throws -> Handshake { try await ensureStarted() }

    public var isRunning: Bool { helper != nil }
    public var helperProcessID: Int32? { helper?.pid }

    public func memoryStats() async throws -> MemoryStats {
        let r = try await call("memory", [:])
        func n(_ k: String) -> Int64 { (r[k] as? NSNumber)?.int64Value ?? 0 }
        return MemoryStats(active: n("active"), cache: n("cache"), peak: n("peak"), peakResident: n("peak_rss"))
    }

    /// Stops the helper now (models are freed). It starts again on next use.
    public func shutdown() async {
        guard let helper else { return }
        let g = generation
        stopping.insert(g)
        if let data = try? JSONSerialization.data(withJSONObject: ["id": 0, "op": "shutdown"]) {
            try? helper.send(data)
        }
        helper.stop()
        detachHelper(reason: "The Python helper was stopped.")
    }

    // MARK: Process lifecycle

    private func locateRuntime() -> PythonRuntime.Lookup {
        if let runtime = configuration.runtime { return .found(runtime) }
        return PythonRuntime.locate()
    }

    private func ensureStarted() async throws -> Handshake {
        if helper != nil, let handshake { return handshake }
        if let startTask { return try await startTask.value }
        let task = Task { try await self.launch() }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    private func launch() async throws -> Handshake {
        let runtime: PythonRuntime
        switch locateRuntime() {
        case .found(let r): runtime = r
        case .needsSetup(let m), .missing(let m): throw EngineError.backendUnavailable(m)
        }
        let started = Date()
        let process: PythonHelperProcess
        do {
            process = try PythonHelperProcess(runtime: runtime,
                                              environment: runtime.environment(ffmpegDirectory: configuration.ffmpegDirectory))
        } catch {
            lastFailure = "Encore couldn't start its Python helper: \(error.localizedDescription)"
            throw EngineError.backendUnavailable(lastFailure!)
        }
        generation += 1
        let g = generation
        helper = process
        resident = []
        Task { [output = process.output] in
            for await item in output { self.receive(item, generation: g) }
        }

        let timeout = Task { [weak process] in
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { process?.kill() }
        }
        defer { timeout.cancel() }
        let reply: [String: Any]
        do {
            reply = try await call("hello", [:], startIfNeeded: false)
        } catch {
            let tail = process.recentStderr().joined(separator: "\n")
            lastFailure = "Encore's Python helper didn't start." + (tail.isEmpty ? "" : " It said:\n\(tail)")
            process.kill()
            throw EngineError.backendUnavailable(lastFailure!)
        }
        let info = Self.parseHandshake(reply)
        guard info.protocolVersion == 1 else {
            process.kill()
            lastFailure = "Encore's Python helper speaks protocol \(info.protocolVersion); this build expects 1."
            throw EngineError.backendUnavailable(lastFailure!)
        }
        handshake = info
        lastFailure = nil
        Self.log.info("Python helper \(process.pid) ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s (\(runtime.origin.rawValue) runtime)")
        scheduleIdleShutdown()
        return info
    }

    private func receive(_ item: PythonHelperProcess.Output, generation g: Int) {
        switch item {
        case .line(let data):
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                Self.log.error("Unreadable line from the Python helper: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                return
            }
            guard let id = (message["id"] as? NSNumber)?.intValue, let entry = pending[id] else { return }
            if message["event"] as? String == "progress" {
                if let fraction = (message["fraction"] as? NSNumber)?.doubleValue { entry.progress?(fraction) }
                return
            }
            pending[id] = nil
            if message["ok"] as? Bool == true {
                let result = message["result"] as? [String: Any] ?? [:]
                entry.continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8))
            } else {
                entry.continuation.resume(throwing: Self.error(from: message["error"] as? [String: Any], op: entry.op))
            }
            cancelledIDs.remove(id)
            if pending.isEmpty { scheduleIdleShutdown() }

        case .exited(let status, let signaled):
            let intentional = stopping.remove(g) != nil
            let reason = signaled ? "was killed (signal \(status))" : "quit (exit code \(status))"
            var message = "The Python helper \(reason) while working."
            if signaled && status == SIGKILL {
                message += " macOS may have stopped it for using too much memory."
            } else if !intentional, let process = helper, generation == g,
                      let last = process.recentStderr(12).last(where: { line in
                          ["Error", "Exception", "Traceback", "abort", "Fatal", "fault"].contains { line.contains($0) }
                      }) {
                message += " Last error: \(last)"
            }
            if !intentional { Self.log.error("\(message, privacy: .public)") }
            for (id, entry) in pending where entry.generation == g {
                pending[id] = nil
                if cancelledIDs.remove(id) != nil {
                    entry.continuation.resume(throwing: CancellationError())
                } else {
                    entry.continuation.resume(throwing: EngineError.failed(intentional ? "The Python helper was stopped." : message))
                }
            }
            if generation == g, helper != nil { detachHelper(reason: message) }
        }
    }

    private func detachHelper(reason: String) {
        helper = nil
        resident = []
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let g = generation, delay = configuration.idleShutdown
        idleTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.idleCheck(generation: g)
        }
    }

    private func idleCheck(generation g: Int) async {
        guard g == generation, helper != nil, pending.isEmpty else { return }
        Self.log.info("Stopping the idle Python helper")
        await shutdown()
    }

    // MARK: Requests

    private func call(_ op: String, _ payload: [String: Any], progress: EngineProgress? = nil,
                      startIfNeeded: Bool = true) async throws -> [String: Any] {
        if startIfNeeded { _ = try await ensureStarted() }
        guard let helper else { throw EngineError.backendUnavailable(lastFailure ?? "The Python helper isn't running.") }
        try Task.checkCancellation()
        idleTask?.cancel()
        let id = nextID
        nextID += 1
        var message = payload
        message["id"] = id
        message["op"] = op
        let data = try JSONSerialization.data(withJSONObject: message)
        let g = generation

        let result: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                pending[id] = Pending(continuation: continuation, progress: progress, generation: g, op: op)
                do {
                    try helper.send(data)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: EngineError.failed("Couldn't talk to the Python helper: \(error.localizedDescription)"))
                    return
                }
                if Task.isCancelled { requestCancel(id) }
            }
        } onCancel: {
            Task { await self.requestCancel(id) }
        }
        return (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] ?? [:]
    }

    private func requestCancel(_ id: Int) {
        guard let entry = pending[id], let helper, entry.generation == generation else { return }
        guard cancelledIDs.insert(id).inserted else { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["id": nextID, "op": "cancel", "target": id]) {
            nextID += 1
            try? helper.send(data)
        }
        let g = generation, grace = configuration.cancelGrace
        Task {
            try? await Task.sleep(for: .seconds(grace))
            await self.enforceCancel(id, generation: g)
        }
    }

    private func enforceCancel(_ id: Int, generation g: Int) {
        guard pending[id] != nil, g == generation, let helper else { return }
        Self.log.error("The Python helper didn't stop job \(id) within \(self.configuration.cancelGrace) s; killing it")
        helper.kill()  // .exited fails the job with CancellationError and everything else with an error
    }

    private func sendLoad(_ context: ModelLoadContext) async throws {
        let repos = context.variant.allRepos
        var dirs: [String: String] = [:]
        for repo in repos {
            guard let url = context.repoDirectories[repo] else {
                throw EngineError.failed("\(context.manifest.name) needs \(repo), which isn't downloaded.")
            }
            dirs[repo] = url.path
        }
        _ = try await call("load", [
            "model_id": context.manifest.id, "engine": context.manifest.engine,
            "task": context.manifest.tasks.map(\.rawValue), "repo": context.variant.repo, "repo_dirs": dirs,
        ])
        resident.insert(context.manifest.id)
    }

    private func ensureResident(_ modelID: String) async throws {
        _ = try await ensureStarted()
        if resident.contains(modelID) { return }
        guard let context = contexts[modelID] else { throw EngineError.modelNotLoaded(modelID) }
        Self.log.info("Reloading \(modelID, privacy: .public) in the Python helper")
        try await sendLoad(context)
    }

    // MARK: Helpers

    private static func voicePayload(_ voice: EngineVoice) -> [String: Any] {
        var v: [String: Any] = [:]
        if let p = voice.preset { v["preset"] = p }
        if let a = voice.referenceAudio { v["reference_audio"] = a.path }
        if let t = voice.referenceText { v["reference_text"] = t }
        return v
    }

    private static func scratchFile() -> URL {
        EncorePaths.scratch.appendingPathComponent("python-\(UUID().uuidString).wav")
    }

    private static func logIgnored(_ result: [String: Any], _ modelID: String) {
        if let ignored = result["ignored"] as? [String], !ignored.isEmpty {
            log.info("\(modelID, privacy: .public) ignored parameters: \(ignored.joined(separator: ", "), privacy: .public)")
        }
    }

    private static func error(from payload: [String: Any]?, op: String) -> Error {
        let code = payload?["code"] as? String ?? "internal"
        let message = payload?["message"] as? String ?? "The Python helper hit an error."
        if let detail = payload?["detail"] as? String, !detail.isEmpty {
            log.error("\(op, privacy: .public) failed [\(code, privacy: .public)]: \(message, privacy: .public) — \(detail, privacy: .public)")
        }
        switch code {
        case "cancelled": return CancellationError()
        case "model_not_loaded": return EngineError.failed(message)
        case "unsupported", "unsupported_engine": return EngineError.unsupported(message)
        default: return EngineError.failed(message)
        }
    }

    static let featureNames: [String: EngineFeatures] = [
        "synthesis": .synthesis, "cloning": .cloning, "voiceDesign": .voiceDesign,
        "transcription": .transcription, "wordTimestamps": .wordTimestamps, "voiceConversion": .voiceConversion,
    ]

    private static func parseHandshake(_ r: [String: Any]) -> Handshake {
        var engines: [String: EngineFeatures] = [:]
        for (key, value) in r["engines"] as? [String: [String]] ?? [:] {
            engines[key] = value.reduce(into: EngineFeatures()) { $0.formUnion(featureNames[$1] ?? []) }
        }
        return Handshake(
            protocolVersion: (r["protocol"] as? NSNumber)?.intValue ?? 0,
            helperVersion: r["helper"] as? String ?? "?",
            pythonVersion: r["python"] as? String ?? "?",
            packages: (r["packages"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String },
            engines: engines,
            unavailable: r["unavailable"] as? [String: String] ?? [:])
    }
}

/// Reads the float32 (or 16-bit PCM) mono WAV files the helper writes.
enum PythonWAV {
    static func read(_ url: URL) throws -> AudioBuffer {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw EngineError.failed("The Python helper didn't produce an audio file.")
        }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u16(_ o: Int) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) } }
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw EngineError.failed("The Python helper wrote an unreadable audio file.")
        }
        var offset = 12, format: UInt16 = 0, channels: UInt16 = 1, rate: UInt32 = 0, bits: UInt16 = 0
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                let end = min(body + size, data.count)
                let bytes = data[body..<end]
                var samples: [Float]
                switch (format, bits) {
                case (3, 32):  // copied, because the data chunk needn't be 4-byte aligned
                    samples = [Float](repeating: 0, count: bytes.count / 4)
                    _ = samples.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
                case (1, 16):
                    var ints = [Int16](repeating: 0, count: bytes.count / 2)
                    _ = ints.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
                    samples = ints.map { Float($0) / 32768 }
                default:
                    throw EngineError.failed("The Python helper wrote audio in an unexpected format (\(format)/\(bits)).")
                }
                if channels > 1 {
                    let c = Int(channels)
                    samples = stride(from: 0, to: samples.count - c + 1, by: c).map { i in
                        samples[i..<i + c].reduce(0, +) / Float(c)
                    }
                }
                return AudioBuffer(samples: samples, sampleRate: Double(rate))
            }
            offset = body + size + (size & 1)
        }
        throw EngineError.failed("The Python helper wrote an audio file with no audio.")
    }
}
