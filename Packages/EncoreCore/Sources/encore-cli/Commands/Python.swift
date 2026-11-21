import EncoreCore
import EncoreMLX
import Foundation

// encore-cli python status [--hold SECONDS]
// encore-cli python speak --engine voxcpm2 --repo mlx-community/VoxCPM2-8bit --text "…" --out a.wav
//            [--voice NAME] [--ref ref.wav] [--ref-text "…"] [--instruct "…"] [--language en] [--param k=v]…
// encore-cli python transcribe --audio a.wav [--engine whisper] [--repo …] [--words] [--language en]
// encore-cli python convert --source in.wav --target ref.wav --out out.wav [--param n_timesteps=10]
// encore-cli python memory-test | cancel-test | crash-test   (same model options as speak)
func runPythonCommand(_ args: [String]) async throws {
    guard let sub = args.first else {
        print("usage: encore-cli python <status|speak|transcribe|convert|memory-test|cancel-test|crash-test> …")
        exit(2)
    }
    let o = CLIOptions(Array(args.dropFirst()))
    let backend = PythonBackend()

    switch sub {
    case "status":
        print("availability: \(await backend.availability())")
        if case .found(let r) = PythonRuntime.locate() {
            print("runtime: \(r.origin.rawValue) \(r.executable.path)\nhelper:  \(r.helperRoot.path)")
        }
        let started = Date()
        let info = try await backend.start()
        print(String(format: "cold start (spawn → handshake): %.2f s, pid %d", Date().timeIntervalSince(started),
                     await backend.helperProcessID ?? -1))
        print("helper \(info.helperVersion), protocol \(info.protocolVersion), Python \(info.pythonVersion)")
        print("packages: " + info.packages.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        for (key, features) in info.engines.sorted(by: { $0.key < $1.key }) {
            print("  \(key.padding(toLength: 18, withPad: " ", startingAt: 0)) \(describe(features))")
        }
        for (key, why) in info.unavailable.sorted(by: { $0.key < $1.key }) { print("  \(key): unavailable — \(why)") }
        let engines = await backend.engineFeatures()
        print("engineFeatures() reports \(engines.count) engines")
        if let hold = o.double("hold") {
            print("holding for \(hold) s"); fflush(stdout)
            try await Task.sleep(for: .seconds(hold))
        }
        await backend.shutdown()

    case "speak":
        let context = try o.loadContext(task: "tts")
        try await timed("load") { try await backend.load(context) }
        var job = o.synthesisJob(modelID: context.manifest.id)
        job.parameters = context.manifest.defaultParameters.merging(job.parameters) { $1 }
        let audio = try await timed("synthesize") { try await backend.synthesize(job, progress: printProgress) }
        try writeWAV(audio, to: o.url("out", default: "speech.wav"))
        print(String(format: "wrote %@: %.2f s at %.0f Hz", o.string("out") ?? "speech.wav", audio.duration, audio.sampleRate))
        await backend.shutdown()

    case "transcribe":
        var o = o
        if o.string("engine") == nil { o.values["engine"] = "whisper" }
        if o.string("repo") == nil { o.values["repo"] = "mlx-community/whisper-large-v3-turbo-asr-fp16" }
        let context = try o.loadContext(task: "stt")
        try await timed("load") { try await backend.load(context) }
        let job = TranscriptionJob(modelID: context.manifest.id, audio: try o.requiredURL("audio"),
                                   language: o.string("language"), timestamps: o.flag("words") ? .word : .segment,
                                   parameters: o.params)
        let t = try await timed("transcribe") { try await backend.transcribe(job, progress: printProgress) }
        print("text: \(t.text)\nlanguage: \(t.language ?? "?"), duration \(t.duration.map { String(format: "%.2f s", $0) } ?? "?")")
        for s in t.segments {
            print(String(format: "[%6.2f – %6.2f] %@", s.start, s.end, s.text))
            for w in s.words ?? [] { print(String(format: "      %6.2f – %6.2f  %@", w.start, w.end, w.text)) }
        }
        await backend.shutdown()

    case "convert":
        let (catalog, _) = ModelCatalog.bundled()
        guard let manifest = catalog.model(o.string("model") ?? "chatterbox-vc") else { throw CLIError("manifest not found") }
        let variant = manifest.variant(o.string("variant"))
        let context = ModelLoadContext(manifest: manifest, variant: variant,
                                       repoDirectories: try snapshotDirectories(variant.allRepos))
        try await timed("load") { try await backend.load(context) }
        let source = try o.requiredURL("source")
        let job = VoiceConversionJob(modelID: manifest.id, source: source,
                                     target: EngineVoice(referenceAudio: try o.requiredURL("target")),
                                     parameters: manifest.defaultParameters.merging(o.params) { $1 })
        let audio = try await timed("convert") { try await backend.convertVoice(job, progress: printProgress) }
        try writeWAV(audio, to: o.url("out", default: "converted.wav"))
        print(String(format: "wrote %@: %.2f s at %.0f Hz", o.string("out") ?? "converted.wav", audio.duration, audio.sampleRate))
        let stats = try await backend.memoryStats()
        print("helper memory: MLX active \(gb(stats.active)), MLX peak \(gb(stats.peak)), peak RSS \(gb(stats.peakResident))")
        await backend.shutdown()

    case "memory-test":
        let context = try o.loadContext(task: "tts")
        print("before load: \(try await memoryLine(backend))")
        try await timed("load") { try await backend.load(context) }
        print("after load:  \(try await memoryLine(backend))")
        _ = try await timed("synthesize") { try await backend.synthesize(o.synthesisJob(modelID: context.manifest.id), progress: nil) }
        print("after job:   \(try await memoryLine(backend))")
        await backend.unload(modelID: context.manifest.id)
        print("after unload: \(try await memoryLine(backend)); loaded: \(await backend.loadedModelIDs())")
        await backend.shutdown()

    case "cancel-test":
        let context = try o.loadContext(task: "tts")
        try await backend.load(context)
        let job = o.synthesisJob(modelID: context.manifest.id)
        let after = o.double("after") ?? 1.0
        let task = Task { try await backend.synthesize(job, progress: printProgress) }
        try await Task.sleep(for: .seconds(after))
        let cancelAt = Date()
        task.cancel()
        do {
            let audio = try await task.value
            print(String(format: "job finished before the cancel landed (%.2f s of audio)", audio.duration))
        } catch is CancellationError {
            print(String(format: "canceled after %.2f s; the job stopped %.3f s after cancel()", after, Date().timeIntervalSince(cancelAt)))
        }
        print("helper still running: \(await backend.isRunning), pid \(await backend.helperProcessID ?? -1)")
        var short = job
        short.text = "Still working after the cancel."
        let audio = try await timed("next job") { try await backend.synthesize(short, progress: nil) }
        print(String(format: "next job OK: %.2f s of audio", audio.duration))
        await backend.shutdown()

    case "crash-test":
        let context = try o.loadContext(task: "tts")
        try await backend.load(context)
        let job = o.synthesisJob(modelID: context.manifest.id)
        guard let pid = await backend.helperProcessID else { throw CLIError("helper not running") }
        let task = Task { try await backend.synthesize(job, progress: nil) }
        try await Task.sleep(for: .seconds(o.double("after") ?? 1.0))
        print("killing helper pid \(pid) with SIGKILL mid-job")
        kill(pid, SIGKILL)
        do {
            _ = try await task.value
            print("job unexpectedly succeeded")
        } catch {
            print("job failed as expected: \(error.localizedDescription)")
        }
        print("running: \(await backend.isRunning); loaded: \(await backend.loadedModelIDs())")
        var short = job
        short.text = "Back on my feet after a crash."
        let audio = try await timed("retry (restarts helper, reloads model)") { try await backend.synthesize(short, progress: nil) }
        print(String(format: "recovered: %.2f s of audio from new helper pid %d", audio.duration, await backend.helperProcessID ?? -1))
        if let out = o.string("out") { try writeWAV(audio, to: URL(fileURLWithPath: out)) }
        await backend.shutdown()

    default:
        throw CLIError("unknown python subcommand: \(sub)")
    }
}

// MARK: - Helpers

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct CLIOptions {
    var values: [String: String] = [:]
    var multi: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                values[key] = args[i + 1]
                multi[key, default: []].append(args[i + 1])
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        }
    }

    func string(_ k: String) -> String? { values[k] }
    func double(_ k: String) -> Double? { values[k].flatMap(Double.init) }
    func flag(_ k: String) -> Bool { flags.contains(k) }
    func url(_ k: String, default d: String) -> URL { URL(fileURLWithPath: values[k] ?? d) }
    func requiredURL(_ k: String) throws -> URL {
        guard let v = values[k] else { throw CLIError("missing --\(k)") }
        return URL(fileURLWithPath: v)
    }

    var params: ParamValues {
        var p: ParamValues = [:]
        for kv in multi["param"] ?? [] {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let v = parts[1]
            p[parts[0]] = Int(v).map(ParamValue.int) ?? Double(v).map(ParamValue.double)
                ?? (v == "true" || v == "false" ? .bool(v == "true") : .string(v))
        }
        return p
    }

    func synthesisJob(modelID: String) -> SynthesisJob {
        var voice: EngineVoice?
        if values["voice"] != nil || values["ref"] != nil {
            voice = EngineVoice(preset: values["voice"], referenceAudio: values["ref"].map { URL(fileURLWithPath: $0) },
                                referenceText: values["ref-text"])
        }
        return SynthesisJob(modelID: modelID, text: values["text"] ?? "Hello from Encore.", voice: voice,
                            instruct: values["instruct"], language: values["language"], parameters: params)
    }

    /// A throwaway manifest for `--engine/--repo`, or a bundled one for `--model`.
    func loadContext(task: String) throws -> ModelLoadContext {
        if let id = values["model"], let manifest = ModelCatalog.bundled().catalog.model(id) {
            let variant = manifest.variant(values["variant"])
            return ModelLoadContext(manifest: manifest, variant: variant, repoDirectories: try snapshotDirectories(variant.allRepos))
        }
        guard let engine = values["engine"], let repo = values["repo"] else { throw CLIError("need --engine and --repo (or --model)") }
        let companions = multi["companion"] ?? []
        let json: [String: Any] = [
            "id": values["model"] ?? engine, "name": engine, "family": engine, "summary": "", "tasks": [task],
            "engine": engine, "license": ["name": "unknown"], "capabilities": [:], "languages": [],
            "presetVoices": [], "expressiveTags": [], "parameters": [], "maxChunkCharacters": 0, "sampleRate": 24000,
            "variants": [["id": "cli", "label": "cli", "repo": repo, "companionRepos": companions,
                          "downloadBytes": 0, "memoryBytes": 0]],
        ]
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json))
        return ModelLoadContext(manifest: manifest, variant: manifest.variants[0],
                                repoDirectories: try snapshotDirectories([repo] + companions))
    }
}

/// Repo id → `<hub>/models--org--name/snapshots/<refs/main>`.
private func snapshotDirectories(_ repos: [String]) throws -> [String: URL] {
    var dirs: [String: URL] = [:]
    for repo in repos {
        let base = EncorePaths.huggingFaceHub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        let sha = (try? String(contentsOf: base.appendingPathComponent("refs/main"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshots = base.appendingPathComponent("snapshots")
        guard let name = sha ?? (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path))?.first else {
            throw CLIError("\(repo) isn't in the Hugging Face cache")
        }
        dirs[repo] = snapshots.appendingPathComponent(name)
    }
    return dirs
}

private func describe(_ f: EngineFeatures) -> String {
    let names: [(EngineFeatures, String)] = [(.synthesis, "synthesis"), (.cloning, "cloning"), (.voiceDesign, "voiceDesign"),
                                             (.transcription, "transcription"), (.wordTimestamps, "wordTimestamps"),
                                             (.voiceConversion, "voiceConversion")]
    return names.filter { f.contains($0.0) }.map(\.1).joined(separator: ", ")
}

private let printProgress: EngineProgress = { fraction in
    FileHandle.standardError.write(Data(String(format: "  progress %.0f%%\n", fraction * 100).utf8))
}

private func timed<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
    let start = Date()
    let value = try await body()
    print(String(format: "%@: %.2f s", label, Date().timeIntervalSince(start)))
    return value
}

private func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

private func memoryLine(_ backend: PythonBackend) async throws -> String {
    let s = try await backend.memoryStats()
    return "MLX active \(gb(s.active)), cache \(gb(s.cache)), peak \(gb(s.peak))"
}

private func writeWAV(_ audio: AudioBuffer, to url: URL) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let rate = UInt32(audio.sampleRate), bytes = UInt32(audio.samples.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1); u32(rate); u32(rate * 4); u16(4); u16(32)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    audio.samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
}
