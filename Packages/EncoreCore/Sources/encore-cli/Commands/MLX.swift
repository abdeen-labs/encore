import EncoreCore
import EncoreMLX
import Foundation
import MLXAudioCore

// encore-cli mlx speak --model <id> [--variant v] --text "…" [--voice preset] [--ref clip.wav --ref-text "…"]
//                      [--instruct "…"] [--lang code] [--param key=value …] [--out file.wav] [--check <stt model id>]
// encore-cli mlx transcribe --model <id> [--variant v] --audio file [--lang code] [--timestamps none|segment|word]
//                           [--param key=value …] [--expect "reference text"]
// encore-cli mlx mem --model <id> [--variant v]          load, report memory, unload, report again
// encore-cli mlx features
//
// Models are read from the standard Hugging Face cache; nothing is downloaded. Run with HF_HUB_OFFLINE=1 to be sure.

func runMLXCommand(_ args: [String]) async throws {
    guard let sub = args.first else {
        print("usage: encore-cli mlx <speak|transcribe|mem|features> …")
        exit(2)
    }
    let options = CLIOptions(Array(args.dropFirst()))
    let backend = MLXSwiftBackend()
    switch sub {
    case "features":
        for (engine, features) in await backend.engineFeatures().sorted(by: { $0.key < $1.key }) {
            print(engine, describe(features))
        }
    case "speak": try await speak(options, backend: backend)
    case "transcribe": try await transcribeCommand(options, backend: backend)
    case "mem": try await memCommand(options, backend: backend)
    default:
        print("unknown mlx subcommand: \(sub)")
        exit(2)
    }
}

private func speak(_ o: CLIOptions, backend: MLXSwiftBackend) async throws {
    let (manifest, variant) = try resolveModel(o)
    guard let text = o["text"] else { throw CLIError("--text is required") }
    let out = URL(fileURLWithPath: o["out"] ?? "out.wav")
    let load = try await timedLoad(manifest, variant, backend: backend)

    var voice: EngineVoice?
    if o["voice"] != nil || o["ref"] != nil {
        voice = EngineVoice(preset: o["voice"], referenceAudio: o["ref"].map { URL(fileURLWithPath: $0) }, referenceText: o["ref-text"])
    }
    let job = SynthesisJob(modelID: manifest.id, text: text, voice: voice, instruct: o["instruct"],
                           language: o["lang"], parameters: o.parameters(for: manifest))
    // --cancel-after S starts the job, cancels its task after S seconds and reports how long it took to stop.
    if let after = o["cancel-after"].flatMap(Double.init) {
        let task = Task { try await backend.synthesize(job, progress: nil) }
        try await Task.sleep(for: .seconds(after))
        let cancelled = Date()
        task.cancel()
        do {
            let audio = try await task.value
            print(String(format: "finished anyway (%.2f s of audio) %.2f s after cancel", audio.duration, Date().timeIntervalSince(cancelled)))
        } catch {
            print(String(format: "stopped %.2f s after cancel: %@", Date().timeIntervalSince(cancelled), "\(error)"))
        }
        await backend.unload(modelID: manifest.id)
        print("after unload: \(await backend.memory())")
        return
    }

    // --repeat N runs the same job N times in one process: the first run includes Metal kernel
    // compilation, later ones show the steady-state speed; the checksum shows whether a seed reproduces.
    let repeats = max(1, Int(o["repeat"] ?? "1") ?? 1)
    var audio = AudioBuffer(sampleRate: 0)
    var peak = 0
    for run in 1...repeats {
        await backend.resetPeakMemory()
        let start = Date()
        audio = try await backend.synthesize(job, progress: nil)
        let seconds = Date().timeIntervalSince(start)
        peak = max(peak, await backend.memory().peak)
        let rms = sqrt(audio.samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, audio.samples.count)))
        let checksum = audio.samples.prefix(200_000).enumerated().reduce(0.0) { $0 + Double($1.element) * Double($1.offset % 97 + 1) }
        print(String(format: "run %d: %.2f s of audio at %.0f Hz in %.2f s (RTF %.3f), rms %.4f, checksum %.6f",
                     run, audio.duration, audio.sampleRate, seconds, seconds / max(audio.duration, 0.001), rms, checksum))
    }
    try AudioUtils.writeWavFile(samples: audio.samples, sampleRate: audio.sampleRate, fileURL: out)
    print("wrote \(out.path)")
    print("peak during generation: \(gb(peak)); peak since load: \(gb(max(peak, load.peak)))")
    await backend.unload(modelID: manifest.id)
    print("after unload: \(await backend.memory())")

    if let checker = o["check"] {
        let (sttManifest, sttVariant) = try resolveModel(id: checker, variant: nil)
        _ = try await timedLoad(sttManifest, sttVariant, backend: backend, quiet: true)
        let transcript = try await backend.transcribe(
            TranscriptionJob(modelID: sttManifest.id, audio: out, language: nil, timestamps: .segment), progress: nil)
        await backend.unload(modelID: sttManifest.id)
        print("round trip (\(sttManifest.id)): \"\(transcript.text)\"")
        print(String(format: "word error rate vs input: %.1f%%", wordErrorRate(reference: text, hypothesis: transcript.text) * 100))
    }
}

private func transcribeCommand(_ o: CLIOptions, backend: MLXSwiftBackend) async throws {
    let (manifest, variant) = try resolveModel(o)
    guard let audioPath = o["audio"] else { throw CLIError("--audio is required") }
    let granularity = TimestampGranularity(rawValue: o["timestamps"] ?? "segment") ?? .segment
    _ = try await timedLoad(manifest, variant, backend: backend)
    await backend.resetPeakMemory()
    let start = Date()
    let transcript = try await backend.transcribe(
        TranscriptionJob(modelID: manifest.id, audio: URL(fileURLWithPath: audioPath), language: o["lang"],
                         timestamps: granularity, parameters: o.parameters(for: manifest)),
        progress: nil)
    let seconds = Date().timeIntervalSince(start)
    let peak = await backend.memory().peak
    let duration = transcript.duration ?? 0
    print(String(format: "transcribed %.2f s of audio in %.2f s (RTF %.3f), language %@",
                 duration, seconds, seconds / max(duration, 0.001), transcript.language ?? "?"))
    print("text: \(transcript.text)")
    var monotonic = true
    var previousEnd = 0.0
    for s in transcript.segments {
        if s.start < previousEnd - 0.01 || s.end < s.start || s.end > duration + 0.5 { monotonic = false }
        previousEnd = s.end
        print(String(format: "  [%7.2f → %7.2f] %@", s.start, s.end, s.text))
    }
    print("segments: \(transcript.segments.count), monotonic and in range: \(monotonic)")
    if let expect = o["expect"] {
        print(String(format: "word error rate vs expected: %.1f%%", wordErrorRate(reference: expect, hypothesis: transcript.text) * 100))
    }
    print("peak during transcription: \(gb(peak))")
    await backend.unload(modelID: manifest.id)
    print("after unload: \(await backend.memory())")
}

private func memCommand(_ o: CLIOptions, backend: MLXSwiftBackend) async throws {
    let (manifest, variant) = try resolveModel(o)
    print("before load: \(await backend.memory())")
    _ = try await timedLoad(manifest, variant, backend: backend)
    await backend.unload(modelID: manifest.id)
    print("after unload: \(await backend.memory())")
}

// MARK: - Helpers

private struct LoadStats { var seconds: Double; var active: Int; var peak: Int }

private func timedLoad(_ manifest: ModelManifest, _ variant: ModelVariant, backend: MLXSwiftBackend,
                       quiet: Bool = false) async throws -> LoadStats {
    var directories: [String: URL] = [:]
    for repo in variant.allRepos { directories[repo] = try snapshotDirectory(repo) }
    await backend.resetPeakMemory()
    let start = Date()
    try await backend.load(ModelLoadContext(manifest: manifest, variant: variant, repoDirectories: directories))
    let seconds = Date().timeIntervalSince(start)
    let memory = await backend.memory()
    if !quiet {
        print(String(format: "loaded %@ [%@] in %.2f s; ", manifest.id, variant.id, seconds) + "\(memory)")
    }
    return LoadStats(seconds: seconds, active: memory.active, peak: memory.peak)
}

private func resolveModel(_ o: CLIOptions) throws -> (ModelManifest, ModelVariant) {
    guard let id = o["model"] else { throw CLIError("--model is required") }
    return try resolveModel(id: id, variant: o["variant"])
}

private func resolveModel(id: String, variant: String?) throws -> (ModelManifest, ModelVariant) {
    let (catalog, problems) = ModelCatalog.bundled()
    guard let manifest = catalog.model(id) else {
        throw CLIError("no manifest \(id); known: \(catalog.models.map(\.id).joined(separator: ", ")) \(problems)")
    }
    if let variant, !manifest.variants.contains(where: { $0.id == variant }) {
        throw CLIError("\(id) has no variant \(variant); variants: \(manifest.variants.map(\.id).joined(separator: ", "))")
    }
    return (manifest, manifest.variant(variant))
}

/// `<hub>/models--org--name/snapshots/<refs/main>`.
private func snapshotDirectory(_ repo: String) throws -> URL {
    let base = EncorePaths.huggingFaceHub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
    guard let sha = try? String(contentsOf: base.appendingPathComponent("refs/main"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else {
        throw CLIError("\(repo) is not in the Hugging Face cache (\(base.path))")
    }
    return base.appendingPathComponent("snapshots/\(sha)")
}

private func describe(_ f: EngineFeatures) -> String {
    let names: [(EngineFeatures, String)] = [(.synthesis, "synthesis"), (.cloning, "cloning"), (.voiceDesign, "voiceDesign"),
                                             (.transcription, "transcription"), (.wordTimestamps, "wordTimestamps"),
                                             (.voiceConversion, "voiceConversion")]
    return names.filter { f.contains($0.0) }.map(\.1).joined(separator: ",")
}

private func gb(_ bytes: Int) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }

/// Word-level edit distance over lower-cased words with punctuation stripped.
func wordErrorRate(reference: String, hypothesis: String) -> Double {
    func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var row = Array(0...h.count)
    for i in 1...r.count {
        var next = [i] + Array(repeating: 0, count: h.count)
        for j in 1...max(h.count, 1) where j <= h.count {
            next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        row = next
    }
    return Double(row[h.count]) / Double(r.count)
}

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// `--key value` pairs; `--param key=value` may repeat.
private struct CLIOptions {
    var values: [String: String] = [:]
    var params: [(String, String)] = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let key = String(arg.dropFirst(2))
            let value = i + 1 < args.count ? args[i + 1] : ""
            if key == "param", let eq = value.firstIndex(of: "=") {
                params.append((String(value[..<eq]), String(value[value.index(after: eq)...])))
            } else {
                values[key] = value
            }
            i += 2
        }
    }

    subscript(_ key: String) -> String? { values[key] }

    /// Typed by the manifest's parameter spec.
    func parameters(for manifest: ModelManifest) -> ParamValues {
        var result: ParamValues = [:]
        for (key, raw) in params {
            let kind = manifest.parameters.first { $0.key == key }?.type
            switch kind {
            case .int, .seed: result[key] = Int(raw).map(ParamValue.int) ?? .string(raw)
            case .float: result[key] = Double(raw).map(ParamValue.double) ?? .string(raw)
            case .bool: result[key] = .bool(["1", "true", "yes"].contains(raw.lowercased()))
            default: result[key] = Double(raw).map(ParamValue.double) ?? .string(raw)
            }
        }
        return result
    }
}
