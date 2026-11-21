#if DEBUG
import EncoreCore
import EncoreMLX
import Foundation

/// DEBUG only: drives the Clone, Design and Voices screens' own models (`CloneModel`, `DesignModel`, `VoicesModel`,
/// `VoiceTryout`) through real runs inside the app process, without a window or audio output:
///
///     HF_HUB_OFFLINE=1 Encore.app/Contents/MacOS/Encore --voices-headless [clone|design|library|all] [--keep]
///
/// clone:   Kokoro speaks a few sentences; they're stitched into a 4+ minute "interview" with one target sentence in
///          the middle. CloneModel loads it, the selection moves to a filler stretch and then to the target (each settle
///          auto-transcribes), the voice is saved with consent, and VoiceTryout speaks a new line with it on a cloning
///          model; that take is transcribed back and compared with what was asked for.
/// design:  DesignModel auditions two voices for a description, keeps one, discards the other, and the kept voice
///          speaks a line on a cloning model (transcribed back and compared).
/// library: VoicesModel exports a voice to .encorevoice, deletes it, imports it back, and refuses a junk file and an
///          archive holding a symbolic link.
/// Stores live in a temporary folder (deleted at the end unless --keep); the Hugging Face cache is only read.
@MainActor
enum VoiceHeadless {
    static var isRequested: Bool { CommandLine.arguments.contains("--voices-headless") }

    static func run() -> Never {
        Task { @MainActor in exit(await go()) }
        dispatchMain()
    }

    private static let start = Date()
    private static func log(_ s: String) {
        print("[\(String(format: "%7.2f", Date().timeIntervalSince(start)))] \(s)")
        fflush(stdout)
    }

    private struct Env {
        let root: URL
        let service: EncoreService
        let voices: VoiceLibrary
        let settings: AppSettings
        let shelf: ModelShelf
        let history: HistoryDatabase
    }

    static func go() async -> Int32 {
        let fm = FileManager.default
        let args = CommandLine.arguments
        let which = args.firstIndex(of: "--voices-headless").flatMap { i in i + 1 < args.count ? args[i + 1] : nil }
            .flatMap { ["clone", "design", "library", "all"].contains($0) ? $0 : nil } ?? "all"
        let root = fm.temporaryDirectory.appendingPathComponent("EncoreVoicesHeadless-\(ProcessInfo.processInfo.processIdentifier)")
        defer { if !args.contains("--keep") { try? fm.removeItem(at: root) } }
        log("data root: \(root.path) (temporary)")

        // Settings in a temporary folder, never in ~/Library/Preferences.
        let settings = AppSettings(defaults: ThrowawayDefaults.make("EncoreVoicesHeadless").defaults, key: "settings")
        guard let history = try? HistoryDatabase(directory: root.appendingPathComponent("History")) else { log("FAIL history"); return 1 }
        // Headless deletes remove the folder outright rather than filling the user's Trash.
        let voices = VoiceLibrary(directory: root.appendingPathComponent("Voices"), deletesToTrash: false)
        let (catalog, _) = ModelCatalog.bundled()
        let python = PythonBackend()
        let runtime = ModelRuntime(idleMinutes: { 0 }, status: RuntimeStatus(), autoSweep: false)
        let service = EncoreService(catalog: catalog, history: history, voices: voices, pronunciations: PronunciationStore(directory: root),
                                    settings: settings, backends: [MLXSwiftBackend(), python], runtime: runtime,
                                    scratchDirectory: root.appendingPathComponent("Scratch"))
        let shelf = ModelShelf(service: service, downloads: ModelDownloadCenter(catalog: catalog))
        await shelf.waitForScan()
        let env = Env(root: root, service: service, voices: voices, settings: settings, shelf: shelf, history: history)
        log("shelf: \(shelf.downloaded.count) downloaded variants")

        var ok = true
        if which == "clone" || which == "all" { ok = await cloneProof(env) && ok }
        if which == "design" || which == "all" { ok = await designProof(env) && ok }
        if which == "library" || which == "all" { ok = await libraryProof(env) && ok }
        await runtime.waitUntilIdle()
        // Leave nothing running: unload the models and stop the Python helper if it was started.
        await runtime.unloadAll()
        await python.shutdown()
        log(ok ? "PASS (\(which))" : "FAIL (\(which))")
        return ok ? 0 : 1
    }

    // MARK: (a) Clone

    private static func cloneProof(_ env: Env) async -> Bool {
        log("── Clone ──")
        let target = "The lighthouse keeper climbed the spiral stairs every evening, counting each step aloud until he reached the lamp."
        let fillers = [
            "Thanks for having me. It's been a strange year, and I'm still working out how to talk about it.",
            "We recorded most of the album in a converted barn, with the doors open and the rain coming in sideways.",
            "People always ask about the early days, but honestly I remember the van more than the shows.",
        ]
        guard let t = await kokoro(target, voice: "am_michael", env), !t.samples.isEmpty else { log("FAIL Kokoro target"); return false }
        var parts: [AudioBuffer] = []
        let rate = t.sampleRate
        let gap = AudioBuffer(samples: [Float](repeating: 0, count: Int(1.2 * rate)), sampleRate: rate)
        var fillerBuffers: [AudioBuffer] = []
        for f in fillers {
            guard let b = await kokoro(f, voice: "am_michael", env) else { log("FAIL Kokoro filler"); return false }
            fillerBuffers.append(b)
        }
        // ~2 minutes of fillers, the target, then fillers until past 4 minutes.
        var t0: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var fillerSpan: ClosedRange<TimeInterval>?
        var i = 0
        func append(_ b: AudioBuffer) { parts.append(b); parts.append(gap); elapsed += b.duration + gap.duration }
        while elapsed < 120 {
            let b = fillerBuffers[i % fillerBuffers.count]
            if i == 4 { fillerSpan = elapsed...(elapsed + b.duration) }
            append(b); i += 1
        }
        t0 = elapsed
        append(t)
        while elapsed < 250 { append(fillerBuffers[i % fillerBuffers.count]); i += 1 }
        guard let long = try? AudioEdit.concatenate(parts) else { log("FAIL concatenate"); return false }
        let longURL = env.root.appendingPathComponent("long-interview.wav")
        do { try AudioExporter.writeWAV(long, to: longURL) } catch { log("FAIL write long: \(error)"); return false }
        log(String(format: "long source: %.1f s (%@), target sentence at %.2f–%.2f s", long.duration,
                   ByteCountFormatter.string(fromByteCount: Int64((try? FileManager.default.attributesOfItem(atPath: longURL.path)[.size] as? Int) ?? 0), countStyle: .file),
                   t0, t0 + t.duration))

        let model = CloneModel(service: env.service, voices: env.voices, settings: env.settings, shelf: env.shelf)
        await model.prepare()
        log("made for: \(model.modelChoice?.modelID ?? "none") · target length \(model.target)")
        await model.load(longURL)
        guard let source = model.source else { log("FAIL load: \(model.sourceError ?? "?")"); return false }
        log(String(format: "loaded %@ · %.1f s · never refused (long file)", source.name, source.duration))

        // First a filler stretch, then (once that transcript is in) the target: each settle transcribes on its own.
        guard let fs = fillerSpan else { return false }
        model.selection = (fs.lowerBound - 0.2)...(fs.upperBound + 0.2)
        guard let first = await waitForTranscript(model) else { return false }
        log("auto-transcribed filler: “\(first)”")
        let sel = max(0, t0 - 0.25)...(t0 + t.duration + 0.25)
        model.selection = sel
        log(String(format: "selection moved to %.2f–%.2f (%.1f s, verdict %@)", sel.lowerBound, sel.upperBound, model.length, "\(model.lengthVerdict)"))
        guard let text = await waitForTranscript(model, different: first) else { return false }
        let wer1 = wordErrorRate(reference: target, hypothesis: text)
        log(String(format: "auto-transcribed target: “%@” · WER %.2f vs the Kokoro script", text, wer1))

        model.name = "Lighthouse Keeper"
        model.tags = ["narration", "test"]
        if model.blockedReason == nil { log("FAIL save allowed without consent"); return false }
        log("without consent, Save is blocked: “\(model.blockedReason ?? "")”")
        model.consent = true
        await model.save()
        guard let voice = model.saved else { log("FAIL save: \(model.saveError ?? "?")"); return false }
        let ref = env.voices.referenceAudioURL(for: voice.id)
        var refInfo: MediaInfo?
        if let ref { refInfo = try? await AudioReader.probe(ref) }
        let refSize = ref.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) } ?? 0
        log(String(format: "saved “%@” (%@): reference %@, %.2f s, %d bytes; transcript “%@”; consent %@",
                    voice.name, voice.origin.rawValue, ref?.lastPathComponent ?? "-", refInfo?.duration ?? 0, refSize,
                    voice.transcript, voice.consentConfirmedAt.map { "\($0)" } ?? "nil"))
        guard voice.consentConfirmedAt != nil, abs((refInfo?.duration ?? 0) - model.length) < 0.1 else { log("FAIL saved clip"); return false }

        // Hear it.
        let tryout = model.tryout
        tryout.line = "Please remember to bring an umbrella tomorrow, because the forecast says heavy rain."
        log("try it with \(tryout.manifest?.name ?? "no model") (\(tryout.choice?.variantID ?? "-")) — cloning models here: \(tryout.cloningModels(for: voice).map(\.id))")
        return await speakAndCheck(tryout, env)
    }

    // MARK: (b) Design

    private static func designProof(_ env: Env) async -> Bool {
        log("── Design ──")
        let model = DesignModel(service: env.service, settings: env.settings, shelf: env.shelf)
        await model.prepare()
        model.description = DesignModel.examples[1].text
        model.count = 2
        model.parameters = ["seed": .int(7)]
        log("designer: \(model.manifest?.name ?? "none") · “\(model.description)” · sample “\(model.sampleText)”")
        if let r = model.blockedReason { log("FAIL blocked: \(r)"); return false }
        model.run()
        var arrivals: [String] = []
        await watch(model.runner) {
            let n = model.auditions.count
            if n > arrivals.count { arrivals.append(String(format: "Nº %d (%.1f s) while stage “%@”", n, model.auditions.last?.candidate.duration ?? 0, model.runner.stage ?? "-")) }
        }
        log("candidates arrived one by one: \(arrivals)")
        guard model.auditions.count == 2, model.runner.error == nil else {
            log("FAIL auditions \(model.auditions.count), error \(model.runner.error.map { "\($0)" } ?? "none")"); return false
        }
        for a in model.auditions {
            let exists = FileManager.default.fileExists(atPath: a.candidate.audioPath)
            log(String(format: "  audition %d: %.2f s, seed %@, file %@", a.number, a.candidate.duration, a.candidate.seed.map(String.init) ?? "-", exists ? "on disk" : "MISSING"))
        }
        // Each candidate must actually say the sample line (it becomes the voice's reference transcript).
        for a in model.auditions {
            guard let heard = try? await env.service.transcribeReference(URL(fileURLWithPath: a.candidate.audioPath)) else { log("FAIL transcribe audition"); return false }
            let wer = wordErrorRate(reference: model.sampleText, hypothesis: heard.text)
            log(String(format: "  audition %d says “%@” · WER %.2f", a.number, heard.text, wer))
            if wer > 0.25 { log("FAIL audition \(a.number) doesn't say the sample line"); return false }
        }
        let keep = model.auditions[0], other = model.auditions[1]
        model.beginKeeping(keep.id)
        model.keepName = "Night Host"
        model.keepTags = ["radio", "test"]
        await model.keep()
        guard let voice = model.auditions.first(where: { $0.id == keep.id })?.savedVoice else { log("FAIL keep: \(model.saveError ?? "?")"); return false }
        log("kept “\(voice.name)”: origin \(voice.origin.rawValue), source \(voice.sourceModelID ?? "-"), transcript “\(voice.transcript)”, prompt “\(voice.designPrompt ?? "")”")
        model.discardUnsaved()
        let discarded = !FileManager.default.fileExists(atPath: other.candidate.audioPath)
        log("discarded the other audition: file gone \(discarded); auditions left \(model.auditions.count); library has \(env.voices.voices.count) voices")
        guard discarded, voice.origin == .designed, voice.transcript == model.sampleText.trimmingCharacters(in: .whitespacesAndNewlines) else { log("FAIL keep/discard"); return false }
        model.tryout.line = "Good evening, and welcome back to the night desk. The city is quiet, and the coffee is hot."
        log("try it with \(model.tryout.manifest?.name ?? "no model") — the design-then-clone flow")
        return await speakAndCheck(model.tryout, env)
    }

    // MARK: (c) Library

    private static func libraryProof(_ env: Env) async -> Bool {
        log("── Voices ──")
        let model = VoicesModel(library: env.voices)
        var voice = env.voices.voices.first
        if voice == nil {
            guard let b = await kokoro("This is a short reference clip for the library test.", voice: "af_heart", env) else { return false }
            let url = env.root.appendingPathComponent("lib.wav")
            try? AudioExporter.writeWAV(b, to: url)
            voice = try? await env.voices.add(Voice(name: "Library Test", tags: ["test"], origin: .cloned,
                                                   transcript: "This is a short reference clip for the library test.",
                                                   duration: b.duration, consentConfirmedAt: Date()), referenceAudio: url)
        }
        guard let v = voice, let ref = env.voices.referenceAudioURL(for: v.id) else { log("FAIL no voice"); return false }
        let refBytes = (try? Data(contentsOf: ref)) ?? Data()
        let archive = env.root.appendingPathComponent("\(v.name).encorevoice")
        await model.export([v.id], to: archive)
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        log("exported “\(v.name)” → \(archive.lastPathComponent) (\(size) bytes); note: \(model.exportNote ?? "-")")
        guard size > 0 else { return false }
        let before = env.voices.voices.count
        model.delete([v.id])
        log("deleted: library \(before) → \(env.voices.voices.count); folder exists \(FileManager.default.fileExists(atPath: env.voices.folder(for: v.id).path))")

        // A junk file and an archive with a symbolic link, alongside the real one.
        let junk = env.root.appendingPathComponent("not-a-voice.encorevoice")
        try? Data("hello".utf8).write(to: junk)
        let evil = await makeSymlinkArchive(env.root)
        await model.importFiles([archive, junk] + (evil.map { [$0] } ?? []))
        guard let report = model.importReport else { log("FAIL no report"); return false }
        for r in report.refused { log("refused \(r.file): \(r.reason)") }
        guard let back = report.imported.first, let backRef = env.voices.referenceAudioURL(for: back.id) else { log("FAIL import"); return false }
        let same = (try? Data(contentsOf: backRef)) == refBytes
        log("imported “\(back.name)” as \(back.origin.rawValue): transcript equal \(back.transcript == v.transcript), tags \(back.tags), reference bytes identical \(same), consent kept \(back.consentConfirmedAt != nil)")
        let ok = report.imported.count == 1 && report.refused.count == (evil == nil ? 1 : 2) && same && back.transcript == v.transcript
        log(ok ? "library round trip OK" : "FAIL library round trip")
        return ok
    }

    /// A `.encorevoice` whose reference is a symbolic link to a system file: the importer must refuse it.
    private static func makeSymlinkArchive(_ root: URL) async -> URL? {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("evil-src")
        let id = UUID()
        let folder = dir.appendingPathComponent(id.uuidString)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let voice = Voice(id: id, name: "Evil", origin: .cloned, transcript: "x", duration: 1)
        try? JSONEncoder().encode(voice).write(to: folder.appendingPathComponent("voice.json"))
        try? fm.createSymbolicLink(atPath: folder.appendingPathComponent("reference.wav").path, withDestinationPath: "/etc/hosts")
        try? Data("{\"format\":\"encorevoice\",\"version\":1,\"voices\":[\"\(id.uuidString)\"]}".utf8)
            .write(to: dir.appendingPathComponent("encorevoice.json"))
        let out = root.appendingPathComponent("symlink-trick.encorevoice")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-r", "-y", out.path, "."]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return p.terminationStatus == 0 ? out : nil
    }

    // MARK: Helpers

    /// Speaks `text` with Kokoro through the service (as Studio would) and returns the audio.
    private static func kokoro(_ text: String, voice: String, _ env: Env) async -> AudioBuffer? {
        var r = SpeechRequest(modelID: "kokoro", text: text)
        r.voice = .preset(voice)
        do {
            for try await e in env.service.speak(r) {
                if case .finished(let rec) = e { return try await AudioReader.read(rec.audioURL) }
            }
        } catch { log("Kokoro failed: \(error)") }
        return nil
    }

    private static func waitForTranscript(_ model: CloneModel, different: String? = nil) async -> String? {
        var last = ""
        for _ in 0..<2400 {
            let s = "\(model.transcriptState)"
            if s != last { log("  transcript state: \(s.prefix(90))"); last = s }
            switch model.transcriptState {
            case .ready:
                if model.transcript != different { return model.transcript }
            case .failed(let m): log("FAIL transcription: \(m)"); return nil
            case .noModel: log("FAIL no transcription model"); return nil
            default: break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        log("FAIL transcription timed out")
        return nil
    }

    private static func speakAndCheck(_ tryout: VoiceTryout, _ env: Env) async -> Bool {
        if let r = tryout.blockedReason { log("FAIL tryout blocked: \(r)"); return false }
        tryout.speak()
        await watch(tryout.runner) {}
        guard let rec = tryout.result else {
            log("FAIL tryout: \(tryout.runner.error.map { "\($0)" } ?? "no result")"); return false
        }
        log(String(format: "spoke with “%@” on %@: %.2f s in %.2f s → %@", rec.voiceName ?? "-", rec.modelName, rec.duration, rec.elapsed, rec.audioURL.lastPathComponent))
        do {
            let heard = try await env.service.transcribeReference(rec.audioURL)
            let wer = wordErrorRate(reference: tryout.line, hypothesis: heard.text)
            log(String(format: "transcribed back: “%@” · WER %.2f", heard.text, wer))
            return wer <= 0.2
        } catch {
            log("FAIL transcribe back: \(error)"); return false
        }
    }

    private static func watch(_ runner: JobRunner, tick: () -> Void) async {
        var last = ""
        while runner.isBusy {
            if case .confirmMemory(let a) = runner.phase { log("memory: \(a.summary) → run anyway"); runner.runAnyway() }
            let line = "\(runner.phase) · \(runner.stage ?? "-")"
            if line != last { log("  " + line); last = line }
            tick()
            try? await Task.sleep(for: .milliseconds(20))
        }
        tick()
    }

    /// Word-level edit distance over the reference length, ignoring case and punctuation.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var d = Array(0...h.count)
        for i in 1...r.count {
            var prev = d[0]
            d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let tmp = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return Double(d[h.count]) / Double(r.count)
    }
}
#endif
