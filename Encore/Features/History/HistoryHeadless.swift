#if DEBUG
import EncoreCore
import EncoreMLX
import Foundation

/// DEBUG only: proves the History screen's own model (`HistoryModel`, the object the screen uses) against real
/// records made by the real service, inside the app process, with no window and no audio played:
///
///     HF_HUB_OFFLINE=1 Encore.app/Contents/MacOS/Encore --history-headless [--keep]
///
/// Makes two Kokoro takes and a transcription (of one take) through `EncoreService`, then drives search, filters,
/// rename, favorite, export, reuse in Studio (variant, language, post-processing restored) and delete (audio file
/// removed). Also checks that planning runtimes (model pickers, Models screen) never starts the Python helper.
/// Stores live in a temporary folder, deleted at the end unless --keep. Exit status 0 when everything holds.
@MainActor
enum HistoryHeadless {
    static var isRequested: Bool { CommandLine.arguments.contains("--history-headless") }

    static func run() -> Never {
        Task { @MainActor in exit(await go()) }
        dispatchMain()
    }

    private static let start = Date()
    private static var failures: [String] = []

    private static func log(_ s: String) {
        print(String(format: "[%7.2f] ", Date().timeIntervalSince(start)) + s)
        fflush(stdout)
    }

    private static func check(_ ok: Bool, _ what: String) {
        log((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures.append(what) }
    }

    /// `pgrep -fl encore_helper`; with `ownOnly`, only helpers this process started (other Encore runs may have theirs).
    private static func helperProcesses(ownOnly: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = (ownOnly ? ["-P", "\(ProcessInfo.processInfo.processIdentifier)"] : []) + ["-fl", "encore_helper"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func go() async -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("EncoreHistoryHeadless-\(ProcessInfo.processInfo.processIdentifier)")
        defer { if !CommandLine.arguments.contains("--keep") { try? fm.removeItem(at: root) } }
        log("data root: \(root.path) (temporary)")

        let settings = AppSettings(defaults: ThrowawayDefaults.make("EncoreHistoryHeadless").defaults, key: "settings")
        let history: HistoryDatabase
        do { history = try HistoryDatabase(directory: root.appendingPathComponent("History")) } catch { log("FAIL history: \(error)"); return 1 }
        let voices = VoiceLibrary(directory: root.appendingPathComponent("Voices"), deletesToTrash: false)
        let pronunciations = PronunciationStore(directory: root)
        let (catalog, _) = ModelCatalog.bundled()
        let status = RuntimeStatus()
        let runtime = ModelRuntime(idleMinutes: { 0 }, status: status, autoSweep: false)
        let python = PythonBackend()
        let service = EncoreService(catalog: catalog, history: history, voices: voices, pronunciations: pronunciations,
                                    settings: settings, backends: [MLXSwiftBackend(), python], runtime: runtime,
                                    scratchDirectory: root.appendingPathComponent("Scratch"))

        // 1. Runtime planning (what pickers and the Models screen show) must not start Python.
        let before = helperProcesses()
        log("encore_helper processes before: \(before.isEmpty ? "none" : before)")
        let shelf = ModelShelf(service: service, downloads: ModelDownloadCenter(catalog: catalog))
        await shelf.waitForScan()
        await shelf.refreshRuntimes(for: catalog.models)
        await shelf.refreshRuntimes(for: shelf.manifests(for: .tts, requiring: .cloning), requiring: .cloning)
        let library = ModelsLibrary()
        await library.refreshPlans(catalog: catalog, shelf: shelf)
        for m in catalog.models {
            let v = shelf.runtime(for: m)
            let text: String
            switch v {
            case .runs(let r)?: text = r.displayName
            case .blocked(let e)?: text = "blocked: \(e.errorDescription ?? "?")"
            case nil: text = "unknown"
            }
            log("  runtime \(m.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(text)   Models chip: \(library.plans[m.id].map { "\($0)" } ?? "none")")
        }
        try? await Task.sleep(for: .milliseconds(500))
        let after = helperProcesses()
        let mine = helperProcesses(ownOnly: true)
        let pythonRunning = await python.isRunning
        log("encore_helper processes after planning: \(after.isEmpty ? "none" : after)")
        check(!pythonRunning && mine.isEmpty, "planning runtimes for every model started no encore_helper (this process's helpers: \(mine.isEmpty ? "none" : mine))")
        if case .runs(let r)? = shelf.runtime(for: catalog.model("chatterbox-multilingual")!) {
            check(r == .python, "Chatterbox Multilingual is planned on the Python helper, not Native")
            check(library.plans["chatterbox-multilingual"] == .python, "Models screen chip for Chatterbox Multilingual is Python helper")
        } else {
            check(library.plans["chatterbox-multilingual"] != .native, "Chatterbox Multilingual is never shown as Native")
        }

        // 2. Real records through the service.
        guard let kokoro = catalog.model("kokoro") else { log("FAIL no kokoro"); return 1 }
        var post = PostProcessingOptions()
        post.removeSilence = true
        post.targetLUFS = -20
        var r1 = SpeechRequest(modelID: "kokoro", text: "The captain walked onto the stage and the house lights dimmed.")
        r1.variantID = kokoro.defaultVariant.id
        r1.voice = .preset("bf_emma")
        r1.language = "b"
        r1.parameters = ["speed": .double(1.15)]
        r1.post = post
        var r2 = SpeechRequest(modelID: "kokoro", text: "Ladies and gentlemen, please take your seats.")
        r2.voice = .preset("af_heart")
        var takes: [GenerationRecord] = []
        for r in [r1, r2] {
            do {
                for try await e in service.speak(r) { if case .finished(let rec) = e { takes.append(rec) } }
            } catch { log("FAIL speak: \(error)"); return 1 }
        }
        guard takes.count == 2 else { log("FAIL takes \(takes.count)"); return 1 }
        let t1 = takes[0]
        log("take 1: \(t1.title) · \(t1.voiceName ?? "-") · variant \(t1.variantID ?? "nil") · language \(t1.language ?? "nil") · runtime \(t1.runtime?.rawValue ?? "nil") · post \(t1.post.map { "removeSilence \($0.removeSilence), \($0.targetLUFS) LUFS" } ?? "nil") · \(String(format: "%.2f", t1.duration)) s")
        check(t1.variantID == kokoro.defaultVariant.id && t1.language == "b" && t1.post == post && t1.runtime == .mlxSwift,
              "speech record stores variant, language, post-processing and runtime")

        let sttID = ["whisper-large-v3-turbo", "whisper-tiny", "parakeet-tdt-v3"].first { id in
            catalog.model(id).map { service.isDownloaded($0) } ?? false
        }
        var transcript: TranscriptionRecord?
        if let sttID {
            var tr = TranscriptionRequest(modelID: sttID, mediaPath: t1.audioPath)
            tr.language = "en"
            do {
                for try await e in service.transcribe(tr) { if case .finished(let rec) = e { transcript = rec } }
            } catch { log("FAIL transcribe: \(error)") }
            if let t = transcript {
                log("transcript (\(t.modelName), \(t.runtime?.rawValue ?? "?")): “\(t.transcript.text.trimmingCharacters(in: .whitespaces))” · \(t.transcript.segments.count) segments")
                check(t.variantID != nil && t.language == "en" && t.timestamps == .segment, "transcription record stores variant, language and timestamps")
            } else { check(false, "transcription finished") }
        } else {
            log("no transcription model downloaded; skipping the transcription record")
        }

        // 3. The History screen's model.
        let studio = StudioModel(service: service, settings: settings, voices: voices, pronunciations: pronunciations, shelf: shelf, drafts: nil)
        await studio.prepare()
        let model = HistoryModel(service: service, router: nil) { studio }
        await model.waitForResults()
        try? await Task.sleep(for: .milliseconds(200))
        let total = transcript == nil ? 2 : 3
        check(model.items.count == total && model.facets.total == total, "list shows every record, newest first (\(model.items.map(\.title)))")

        model.search = "captain"
        await settle(model)
        let hits = model.items.map(\.title)
        let ranges = HistoryHighlight.ranges(in: t1.text, terms: model.searchTerms)
        check(model.items.contains { $0.id == t1.id } && !model.items.contains { $0.id == takes[1].id },
              "search “captain” finds the take whose script says it, not the other (\(hits))")
        check(ranges.count == 1 && t1.text[ranges[0]] == "captain", "the match is highlighted in the script")
        model.search = "capt"
        await settle(model)
        check(model.items.contains { $0.id == t1.id }, "search matches word prefixes as you type (“capt”)")
        model.search = "emma"
        await settle(model)
        check(model.items.map(\.id) == [t1.id], "search finds voice names (“emma” → \(model.items.map(\.title)))")
        model.search = "kokoro"
        await settle(model)
        check(model.items.filter { $0.generation != nil }.count == 2, "search finds model names")
        if let t = transcript {
            let word = t.transcript.text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.first { $0.count > 5 } ?? "captain"
            model.search = word
            await settle(model)
            check(model.items.contains { $0.id == t.id }, "search finds transcript text (“\(word)”)")
        }
        model.search = ""
        model.kind = .transcription
        await settle(model)
        check(model.items.allSatisfy { $0.kind == .transcription } && model.items.count == (transcript == nil ? 0 : 1), "kind filter: transcripts only")
        model.kind = .all
        model.voice = model.facets.voices.first { $0.name.lowercased().contains("emma") }
        await settle(model)
        check(model.items.map(\.id) == [t1.id], "voice filter (preset voice, by name)")
        model.clearFilters()
        model.modelID = "kokoro"
        model.date = .today
        await settle(model)
        check(model.items.count == 2, "model + date filters")
        model.clearFilters()
        await settle(model)

        // Rename and favorite.
        guard let item1 = model.items.first(where: { $0.id == t1.id }) else { log("FAIL take not listed"); return 1 }
        try? await model.rename(item1, to: "  Captain's entrance  ")
        model.toggleFavorite(item1)
        try? await Task.sleep(for: .milliseconds(300))
        await settle(model)
        let stored = try? await history.item(t1.id)
        check(stored?.title == "Captain's entrance" && stored?.generation?.title == "Captain's entrance", "rename is stored (title trimmed)")
        check(stored?.favorite == true && model.items.first { $0.id == t1.id }?.favorite == true, "favorite is stored and shown")
        model.favoritesOnly = true
        await settle(model)
        check(model.items.map(\.id) == [t1.id], "favorites filter")
        model.favoritesOnly = false
        await settle(model)

        // Export (no panel: straight to a folder).
        let out = root.appendingPathComponent("Export")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let exported = await model.export(model.items, format: .m4a, to: out)
        log("exported: \(exported.written.map(\.lastPathComponent)) failures: \(exported.failures)")
        check(exported.failures.isEmpty && exported.written.count == total, "multi-export writes every item (audio as M4A, transcripts as text)")

        // Reuse in Studio.
        studio.debugSet(choice: ModelChoice(modelID: "kokoro"), script: "something else")
        if let item = model.items.first(where: { $0.id == t1.id }), model.canReuse(item) {
            let problem = model.reuseInStudio(item)
            log("Studio after reuse: model \(studio.choice?.modelID ?? "-") variant \(studio.choice?.variantID ?? "-") voice \(studio.voice) language \(studio.language ?? "nil") parameters \(studio.parameters) post removeSilence \(studio.post.removeSilence) \(studio.post.targetLUFS) LUFS")
            check(problem == nil && studio.choice?.variantID == t1.variantID && studio.language == "b" && studio.post == post
                    && studio.voice == .preset("bf_emma") && studio.parameters["speed"] == .double(1.15) && studio.script == t1.text,
                  "reuse in Studio restores model, variant, voice, language, parameters, post-processing and script")
        } else { check(false, "the take can be reused") }

        // Delete (permanent; audio file goes).
        check(fm.fileExists(atPath: t1.audioPath), "audio file exists before delete")
        model.focusedID = t1.id
        model.click(model.items.first { $0.id == takes[1].id }!, command: true)
        model.requestDelete([t1.id])
        let deleted = (try? await model.confirmDelete()) ?? 0
        await settle(model)
        check(deleted == 1 && !fm.fileExists(atPath: t1.audioPath) && model.focusedID == nil, "delete removes the item and its audio file, and closes the detail")
        let gone = (try? await history.item(t1.id)) == nil
        check(model.items.count == total - 1 && gone, "the record is gone from the database")
        check(fm.fileExists(atPath: takes[1].audioPath), "the other take's audio is untouched")

        try? await Task.sleep(for: .milliseconds(300))
        let end = helperProcesses(ownOnly: true)
        log("this process's encore_helper processes at the end: \(end.isEmpty ? "none" : end)")
        check(end.isEmpty, "no encore_helper of ours is running at the end")
        await runtime.unloadAll()
        log(failures.isEmpty ? "PASS: History model drove real records end to end" : "FAIL: \(failures.count) check(s): \(failures)")
        return failures.isEmpty ? 0 : 1
    }

    private static func settle(_ model: HistoryModel) async {
        try? await Task.sleep(for: .milliseconds(120))
        await model.waitForResults()
    }
}
#endif
