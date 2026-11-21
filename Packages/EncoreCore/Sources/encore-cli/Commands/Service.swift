import EncoreCore
import EncoreMLX
import Foundation

// Drives the real service layer (the same calls the app makes) with the real backends.
//
// encore-cli service speak --model <id> [--variant v] (--text "…" | --text-file f) [--voice V] [--instruct "…"] [--lang l]
//                          [--param k=v …] [--lufs -16 | --no-normalize] [--remove-silence] [--title t] [--out copy.wav]
// encore-cli service transcribe --model <id> --audio <media> [--lang l] [--timestamps none|segment|word]
// encore-cli service reference --audio <clip> [--range 0-8.5] [--model <stt id>] [--lang l]   (nothing saved)
// encore-cli service convert --model <id> --source <media> --voice V
// encore-cli service design --model <id> --description "…" --sample "…" [--candidates 3] [--save-as Name [--save-index 0]]
// encore-cli service conversation --model <id> --script file.txt --cast "Ann=serena,Ben=library:Old Sailor" [--pause 0.4]
// encore-cli service add-voice --name N --audio clip.wav --transcript "…"       (a cloned voice, for testing)
// encore-cli service voices | history
// encore-cli service status [--assess <model>[:variant] …]
// encore-cli service sequence --models a,b,c          load models in turn (one short job each), printing the governor's state
//
// Every request command also takes --json <file|-> with the request body (SpeechRequest, TranscriptionRequest,
// VoiceConversionRequest, VoiceDesignRequest, ConversationRequest) instead of flags, and --events json to print each
// event as a JSON line: the wire format the future HTTP API will use.
//
// Common: --root <dir> keeps history, voices, pronunciations and scratch files there instead of the app's own folders.
// --budget-gb N pretends the Mac has N GB (to watch the governor evict); --idle-minutes N; --prefer <model>=mlxSwift|python.
// V (voice) is "automatic", a preset id, "preset:<id>", "library:<name or uuid>", or a bare library voice name.

@MainActor
func runServiceCommand(_ args: [String]) async throws {
    guard let sub = args.first else {
        print("usage: encore-cli service <speak|transcribe|reference|convert|design|conversation|add-voice|voices|history|status|sequence> …")
        exit(2)
    }
    let o = ServiceCLIOptions(Array(args.dropFirst()))
    let env = try ServiceCLIEnvironment(o)
    defer { env.tearDown() }
    switch sub {
    case "speak":
        var request: SpeechRequest
        if let body = try o.jsonBody() { request = try JSONDecoder().decode(SpeechRequest.self, from: body) } else {
            let text = try o["text"] ?? o["text-file"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? { throw CLIFailure("--text is required") }()
            request = SpeechRequest(modelID: try o.require("model"), text: text)
            request.variantID = o["variant"]
            request.voice = try env.voice(o["voice"])
            request.instruct = o["instruct"]
            request.language = o["lang"]
            request.parameters = env.parameters(o, model: request.modelID)
            request.post = o.post(env.settings.snapshot().postProcessing)
            request.title = o["title"]
        }
        try await env.warnIfTight(request.modelID, request.variantID)
        // --cancel-after S: cancel the consuming task after S seconds, then show what was left behind.
        if let after = o["cancel-after"].flatMap(Double.init) {
            let historyBefore = try await env.history.count()
            let stream = env.service.speak(request)
            let consumer = Task { try await env.drive(stream) }
            try await Task.sleep(for: .seconds(after))
            let canceled = Date()
            consumer.cancel()
            do { _ = try await consumer.value } catch { print("consumer ended: \(error.localizedDescription)") }
            await env.service.runtime.waitUntilIdle()
            let scratch = (FileManager.default.subpaths(atPath: env.service.scratchDirectory.path) ?? []).filter { !$0.hasPrefix("Design") }
            let audioFiles = (try? FileManager.default.contentsOfDirectory(atPath: env.history.audioDirectory.path))?.count ?? 0
            print(String(format: "canceled; request stopped %.2f s later. New history records: %d. Scratch files: %d. "
                         + "History audio files: %d for %d records.", Date().timeIntervalSince(canceled),
                         try await env.history.count() - historyBefore, scratch.count, audioFiles, try await env.history.count()))
            return
        }
        let record = try await env.drive(env.service.speak(request))
        try env.report(record, copyTo: o["out"])

    case "transcribe":
        var request: TranscriptionRequest
        if let body = try o.jsonBody() { request = try JSONDecoder().decode(TranscriptionRequest.self, from: body) } else {
            request = TranscriptionRequest(modelID: try o.require("model"), mediaPath: try o.require("audio"))
            request.variantID = o["variant"]
            request.language = o["lang"]
            request.timestamps = TimestampGranularity(rawValue: o["timestamps"] ?? "segment") ?? .segment
            request.parameters = env.parameters(o, model: request.modelID)
        }
        try await env.warnIfTight(request.modelID, request.variantID)
        let started = Date()
        var record: TranscriptionRecord?
        for try await event in env.service.transcribe(request) {
            env.show(event)
            if case .finished(let r) = event { record = r }
        }
        guard let record else { throw CLIFailure("no record") }
        let t = record.transcript
        print(String(format: "transcribed %.2f s in %.2f s (RTF %.3f), language %@", t.duration ?? 0, Date().timeIntervalSince(started),
                     Date().timeIntervalSince(started) / max(0.001, t.duration ?? 0), t.language ?? "?"))
        print("text: \(t.text)")
        for s in t.segments {
            print(String(format: "  [%7.2f → %7.2f] %@", s.start, s.end, s.text) + (s.words.map { "  (\($0.count) words)" } ?? ""))
        }
        print("history: \(record.id)")

    case "reference":
        let url = URL(fileURLWithPath: try o.require("audio"))
        var range: ClosedRange<TimeInterval>?
        if let r = o["range"] {
            let parts = r.split(separator: "-").compactMap { Double($0) }
            if parts.count == 2 { range = parts[0]...parts[1] }
        }
        let started = Date()
        let t = try await env.service.transcribeReference(url, range: range, language: o["lang"], modelID: o["model"])
        print(String(format: "reference transcript in %.2f s: %@", Date().timeIntervalSince(started), t.text))

    case "convert":
        var request: VoiceConversionRequest
        if let body = try o.jsonBody() { request = try JSONDecoder().decode(VoiceConversionRequest.self, from: body) } else {
            request = VoiceConversionRequest(modelID: try o.require("model"), sourcePath: try o.require("source"),
                                             voice: try env.voice(try o.require("voice")))
            request.variantID = o["variant"]
            request.parameters = env.parameters(o, model: request.modelID)
            request.post = o.post(env.settings.snapshot().postProcessing)
        }
        try await env.warnIfTight(request.modelID, request.variantID)
        let record = try await env.drive(env.service.convertVoice(request))
        try env.report(record, copyTo: o["out"])

    case "design":
        var request: VoiceDesignRequest
        if let body = try o.jsonBody() { request = try JSONDecoder().decode(VoiceDesignRequest.self, from: body) } else {
            request = VoiceDesignRequest(modelID: try o.require("model"), description: try o.require("description"),
                                         sampleText: try o.require("sample"))
            request.variantID = o["variant"]
            request.language = o["lang"]
            request.candidates = Int(o["candidates"] ?? "3") ?? 3
            request.parameters = env.parameters(o, model: request.modelID)
        }
        try await env.warnIfTight(request.modelID, request.variantID)
        let started = Date()
        var candidates: [VoiceDesignCandidate] = []
        for try await event in env.service.designVoice(request) {
            env.show(event)
            if case .candidate(let c) = event {
                candidates.append(c)
                print(String(format: "candidate %d: %.2f s at %.1f s → %@", candidates.count, c.duration, Date().timeIntervalSince(started), c.audioPath))
            }
        }
        if let name = o["save-as"] {
            let index = Int(o["save-index"] ?? "0") ?? 0
            guard candidates.indices.contains(index) else { throw CLIFailure("no candidate \(index)") }
            let voice = try await env.service.saveDesignedVoice(candidates[index], name: name, tags: ["designed"])
            print("saved candidate \(index) as “\(voice.name)” (\(voice.id)), designPrompt: \(voice.designPrompt ?? "-")")
            env.service.discardDesignCandidates(candidates)
        }

    case "conversation":
        var request: ConversationRequest
        if let body = try o.jsonBody() { request = try JSONDecoder().decode(ConversationRequest.self, from: body) } else {
            var script = try ConversationImporter.importFile(at: URL(fileURLWithPath: try o.require("script"))).script
            for pair in (o["cast"] ?? "").split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let i = script.speakers.firstIndex(where: { $0.name.caseInsensitiveCompare(kv[0]) == .orderedSame }) else {
                    throw CLIFailure("cast entry “\(pair)” names no speaker; speakers: \(script.speakers.map(\.name))")
                }
                script.speakers[i].voice = try env.voice(kv[1])
            }
            request = ConversationRequest(modelID: try o.require("model"), script: script)
            request.variantID = o["variant"]
            request.language = o["lang"]
            if let p = o["pause"].flatMap(Double.init) { request.pauseSeconds = p }
            request.parameters = env.parameters(o, model: request.modelID)
            request.post = o.post(env.settings.snapshot().postProcessing)
        }
        try await env.warnIfTight(request.modelID, request.variantID)
        let record = try await env.drive(env.service.renderConversation(request))
        try env.report(record, copyTo: o["out"])
        if o.flag("rerender-last") {
            // Edit the last line and render again: only that line should be generated.
            var again = request
            again.script.lines[again.script.lines.count - 1].text += " Really."
            print("— re-rendering with the last line edited —")
            let second = try await env.drive(env.service.renderConversation(again))
            try env.report(second, copyTo: nil)
        }

    case "add-voice":
        let clip = URL(fileURLWithPath: try o.require("audio"))
        let duration = try await AudioReader.probe(clip).duration
        let voice = try await env.voices.add(Voice(name: try o.require("name"), origin: .cloned, transcript: o["transcript"] ?? "",
                                                   duration: duration, consentConfirmedAt: Date()), referenceAudio: clip)
        print("added “\(voice.name)” \(voice.id) (\(String(format: "%.2f", duration)) s)")

    case "voices":
        for v in env.voices.voices {
            print("\(v.name)  \(v.id)  \(v.origin.rawValue)  \(String(format: "%.1f s", v.duration))  “\(v.transcript.prefix(60))”"
                  + (v.designPrompt.map { "  prompt: \($0)" } ?? ""))
        }

    case "history":
        for item in try await env.history.fetch(limit: 50) {
            print("\(item.createdAt)  \(item.kind.rawValue)  \(item.title)  [\(item.modelName)]")
        }

    case "status":
        await env.printStatus()
        for spec in o.all("assess") {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            let m = try env.service.manifest(parts[0])
            let a = await env.service.runtime.assess(m, m.variant(parts.count > 1 ? parts[1] : nil))
            print("\(m.name) [\(a.variantID)]: \(a.verdict.rawValue) — \(a.summary)")
        }
        for m in env.service.catalog.models where env.service.isDownloaded(m) {
            let runtime = await env.service.plannedRuntime(modelID: m.id)
            let where_: String
            switch runtime { case .success(let r): where_ = r.displayName; case .failure(let e): where_ = "unavailable: \(e.localizedDescription)" }
            print("  \(m.id): downloaded, runs on \(where_)")
        }

    case "sequence":
        let ids = try o.require("models").split(separator: ",").map(String.init)
        for id in ids {
            let m = try env.service.manifest(id)
            let a = await env.service.runtime.assess(m, m.defaultVariant)
            print("== \(m.name): \(a.verdict.rawValue) — \(a.summary)")
            let started = Date()
            if m.tasks.contains(.stt) {
                let clip = try env.toneClip()
                defer { try? FileManager.default.removeItem(at: clip) }
                _ = try await env.service.transcribeReference(clip, modelID: id)
            } else {
                var r = SpeechRequest(modelID: id, text: "Testing the memory governor.")
                if !m.presetVoices.isEmpty { r.voice = .preset(m.presetVoices[0].id) }
                if m.capabilities.voiceDesign, !m.capabilities.presetVoices, !m.capabilities.cloning { r.instruct = "A calm narrator." }
                if m.id == "qwen3-tts-base" { r.voice = .automatic }
                _ = try await env.drive(env.service.speak(r), quiet: true)
            }
            print(String(format: "   job took %.2f s", Date().timeIntervalSince(started)))
            await env.printStatus()
        }
        // --linger S: stay alive S seconds so the idle timer (--idle-minutes) can be watched unloading models.
        if let linger = o["linger"].flatMap(Double.init) {
            let until = Date().addingTimeInterval(linger)
            while Date() < until {
                try await Task.sleep(for: .seconds(min(15, until.timeIntervalSinceNow)))
                print(String(format: "== after %.0f s idle", linger - max(0, until.timeIntervalSinceNow)))
                await env.printStatus()
            }
        }

    default:
        print("unknown service subcommand: \(sub)")
        exit(2)
    }
}

// MARK: - Environment

@MainActor
private final class ServiceCLIEnvironment {
    let settings: AppSettings
    let suite: String
    let history: HistoryDatabase
    let voices: VoiceLibrary
    let pronunciations: PronunciationStore
    let service: EncoreService
    let jsonEvents: Bool
    let root: URL?

    init(_ o: ServiceCLIOptions) throws {
        root = o["root"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        // A throwaway defaults suite per run; tearDown (or exit) removes its domain and plist from ~/Library/Preferences.
        let scratch = ThrowawayDefaults.make("encore-cli")
        suite = scratch.suite
        settings = AppSettings(defaults: scratch.defaults, key: "settings")
        if let m = o["idle-minutes"].flatMap(Int.init) { settings.idleUnloadMinutes = m }
        for p in o.all("prefer") {
            let kv = p.split(separator: "=").map(String.init)
            if kv.count == 2, let pref = AppSettings.RuntimePreference(rawValue: kv[1]) { settings.setRuntimePreference(pref, for: kv[0]) }
        }
        let base = root ?? EncorePaths.applicationSupport
        history = try HistoryDatabase(directory: root.map { $0.appendingPathComponent("History") } ?? EncorePaths.history)
        voices = VoiceLibrary(directory: root.map { $0.appendingPathComponent("Voices") } ?? EncorePaths.voices)
        pronunciations = PronunciationStore(directory: base)
        let (catalog, problems) = ModelCatalog.bundled()
        if !problems.isEmpty { print("manifest problems: \(problems)") }
        let probe: any SystemMemoryProbe = o["budget-gb"].flatMap(Double.init).map { CappedSystemMemory(capBytes: Int64($0 * 1e9)) }
            ?? LiveSystemMemory()
        let settings = self.settings
        let runtime = ModelRuntime(memory: probe, idleMinutes: { settings.snapshot().idleUnloadMinutes })
        let backends: [any EngineBackend] = [MLXSwiftBackend(), PythonBackend()]
        service = EncoreService(catalog: catalog, history: history, voices: voices, pronunciations: pronunciations, settings: settings,
                                backends: backends, runtime: runtime,
                                scratchDirectory: root.map { $0.appendingPathComponent("Scratch") })
        jsonEvents = o["events"] == "json"
    }

    func tearDown() { ThrowawayDefaults.remove(suite) }

    /// "automatic", a preset id, "preset:x", "library:<name|uuid>", or a library voice's name.
    func voice(_ spec: String?) throws -> VoiceSelection {
        guard let spec, !spec.isEmpty, spec != "automatic" else { return .automatic }
        if spec.hasPrefix("preset:") { return .preset(String(spec.dropFirst(7))) }
        let name = spec.hasPrefix("library:") ? String(spec.dropFirst(8)) : spec
        if let id = UUID(uuidString: name), voices.voice(id) != nil { return .library(id) }
        if let v = voices.voices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return .library(v.id) }
        if spec.hasPrefix("library:") { throw CLIFailure("no library voice “\(name)”") }
        return .preset(spec)
    }

    func parameters(_ o: ServiceCLIOptions, model: String) -> ParamValues {
        guard let m = service.catalog.model(model) else { return [:] }
        var result: ParamValues = [:]
        for (key, raw) in o.params {
            switch m.parameters.first(where: { $0.key == key })?.type {
            case .int, .seed: result[key] = Int(raw).map(ParamValue.int) ?? .string(raw)
            case .float: result[key] = Double(raw).map(ParamValue.double) ?? .string(raw)
            case .bool: result[key] = .bool(["1", "true", "yes"].contains(raw.lowercased()))
            default: result[key] = Double(raw).map(ParamValue.double) ?? .string(raw)
            }
        }
        return result
    }

    func warnIfTight(_ modelID: String, _ variantID: String?) async throws {
        let m = try service.manifest(modelID)
        let a = await service.runtime.assess(m, m.variant(variantID))
        if a.verdict != .comfortable { print("memory warning (\(a.verdict.rawValue)): \(a.summary)") }
    }

    func show<E: Encodable>(_ event: E) {
        if jsonEvents {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let d = try? e.encode(event) { print(String(decoding: d, as: UTF8.self)) }
            return
        }
        switch event {
        case let g as GenerationEvent: if case .stage(let s) = g { print("· \(s)") }
        case let t as TranscriptionEvent: if case .stage(let s) = t { print("· \(s)") }
        case let d as VoiceDesignEvent: if case .stage(let s) = d { print("· \(s)") }
        default: break
        }
    }

    func drive(_ stream: AsyncThrowingStream<GenerationEvent, Error>, quiet: Bool = false) async throws -> GenerationRecord {
        let started = Date()
        var last = started
        for try await event in stream {
            if !quiet {
                if !jsonEvents, case .stage(let s) = event {
                    let now = Date()
                    print(String(format: "· %@  (+%.2f s)", s, now.timeIntervalSince(last)))
                    last = now
                } else { show(event) }
            }
            if case .finished(let r) = event { return r }
        }
        throw CLIFailure("finished without a record")
    }

    func report(_ r: GenerationRecord, copyTo out: String?) throws {
        print(String(format: "%@: %.2f s of audio at %.0f Hz in %.2f s (RTF %.3f) — %@", r.kind.rawValue, r.duration, r.sampleRate, r.elapsed,
                     r.elapsed / max(0.001, r.duration), r.title))
        print("model \(r.modelID), voice \(r.voiceName ?? "default"), master \(r.audioPath)")
        if let out {
            let dest = URL(fileURLWithPath: out)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: r.audioURL, to: dest)
            print("copied to \(dest.path)")
        }
    }

    func printStatus() async {
        let snap = await service.runtime.snapshot()
        func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        print("   memory: \(gb(snap.memory.availableBytes)) free of \(gb(snap.memory.physicalBytes)), pressure \(snap.memory.pressure.rawValue)")
        if snap.loaded.isEmpty { print("   loaded: nothing") }
        for m in snap.loaded {
            print("   loaded: \(m.modelName) [\(m.variantLabel)] on \(m.runtime.displayName), \(gb(m.memoryBytes)) peak\(m.isBusy ? ", busy" : "")")
        }
        for u in snap.recentUnloads { print("   unloaded \(u.modelID): \(u.reason)") }
    }

    /// A short spoken-ish clip for exercising a transcription model.
    func toneClip() throws -> URL {
        let url = service.scratchDirectory.appendingPathComponent("sequence-clip.wav")
        let n = 16_000 * 2
        let samples = (0..<n).map { i in Float(0.2 * sin(2 * .pi * 180 * Double(i) / 16_000) * sin(.pi * Double(i) / Double(n))) }
        try AudioExporter.writeWAV(AudioBuffer(samples: samples, sampleRate: 16_000), to: url)
        return url
    }
}

// MARK: - Options

private struct CLIFailure: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// `--key value` pairs (repeatable keys kept in order), bare `--flag`s, and `--param key=value`.
private struct ServiceCLIOptions {
    var pairs: [(String, String)] = []
    var flags: Set<String> = []
    var params: [(String, String)] = []
    static let bareFlags: Set<String> = ["no-normalize", "remove-silence", "rerender-last"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let key = String(arg.dropFirst(2))
            if Self.bareFlags.contains(key) { flags.insert(key); i += 1; continue }
            let value = i + 1 < args.count ? args[i + 1] : ""
            if key == "param", let eq = value.firstIndex(of: "=") {
                params.append((String(value[..<eq]), String(value[value.index(after: eq)...])))
            } else {
                pairs.append((key, value))
            }
            i += 2
        }
    }

    subscript(_ key: String) -> String? { pairs.last { $0.0 == key }?.1 }
    func all(_ key: String) -> [String] { pairs.filter { $0.0 == key }.map(\.1) }
    func flag(_ key: String) -> Bool { flags.contains(key) }
    func require(_ key: String) throws -> String {
        guard let v = self[key], !v.isEmpty else { throw CLIFailure("--\(key) is required") }
        return v
    }

    func jsonBody() throws -> Data? {
        guard let path = self["json"] else { return nil }
        return path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func post(_ defaults: PostProcessingOptions) -> PostProcessingOptions {
        var p = defaults
        if flag("no-normalize") { p.normalizeLoudness = false }
        if let l = self["lufs"].flatMap(Double.init) { p.targetLUFS = l; p.normalizeLoudness = true }
        if flag("remove-silence") { p.removeSilence = true }
        return p
    }
}

