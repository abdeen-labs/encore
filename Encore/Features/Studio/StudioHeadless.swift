#if DEBUG
import EncoreCore
import EncoreMLX
import Foundation

/// DEBUG only: drives the Studio screen's own model (`StudioModel` + `JobRunner`, the same objects the screen uses)
/// through a real generation inside the app process, without opening a window or playing audio:
///
///     HF_HUB_OFFLINE=1 Encore.app/Contents/MacOS/Encore --studio-headless [--model <id>] [--voice <preset id>]   (default: the smallest speech model)
///
/// Stores live in a temporary folder (deleted at the end, unless --keep); the real Hugging Face cache is used read-only.
/// Run 1 performs a short tagged script and prints the record. Run 2 starts a long script, cancels it mid-generation,
/// and checks that nothing was saved and no temporary files were left. Exit status 0 when both behave.
@MainActor
enum StudioHeadless {
    static var isRequested: Bool { CommandLine.arguments.contains("--studio-headless") }

    static func run() -> Never {
        Task { @MainActor in exit(await go()) }
        dispatchMain()
    }

    private static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    private static func log(_ s: String) {
        let t = String(format: "%7.2f", Date().timeIntervalSince(start))
        print("[\(t)] \(s)")
        fflush(stdout)
    }

    private static let start = Date()

    static func go() async -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("EncoreStudioHeadless-\(ProcessInfo.processInfo.processIdentifier)")
        defer { if !CommandLine.arguments.contains("--keep") { try? fm.removeItem(at: root) } }
        log("data root: \(root.path) (temporary)")

        // Throwaway defaults in a temporary folder, never in ~/Library/Preferences (a named suite there can be rewritten
        // by cfprefsd after it was deleted).
        let scratchDefaults = ThrowawayDefaults.make("EncoreStudioHeadless")
        let settings = AppSettings(defaults: scratchDefaults.defaults, key: "settings")
        defer { ThrowawayDefaults.remove(scratchDefaults.suite) }
        let history: HistoryDatabase
        do { history = try HistoryDatabase(directory: root.appendingPathComponent("History")) } catch {
            log("FAIL history: \(error)"); return 1
        }
        let voices = VoiceLibrary(directory: root.appendingPathComponent("Voices"), deletesToTrash: false)
        let pronunciations = PronunciationStore(directory: root)
        try? pronunciations.save(PronunciationEntry(term: "Encore", replacement: "on-core"))
        let (catalog, _) = ModelCatalog.bundled()
        let status = RuntimeStatus()
        let runtime = ModelRuntime(idleMinutes: { 0 }, status: status, autoSweep: false)
        let scratch = root.appendingPathComponent("Scratch")
        let service = EncoreService(catalog: catalog, history: history, voices: voices, pronunciations: pronunciations,
                                    settings: settings, backends: [MLXSwiftBackend(), PythonBackend()], runtime: runtime,
                                    scratchDirectory: scratch)
        let shelf = ModelShelf(service: service, downloads: ModelDownloadCenter(catalog: catalog))
        let model = StudioModel(service: service, settings: settings, voices: voices, pronunciations: pronunciations,
                                shelf: shelf, drafts: nil)
        await model.prepare()
        log("shelf: \(shelf.downloaded.count) downloaded variants; starting model: \(model.choice?.modelID ?? "none")")

        // The smallest speech model unless one is asked for (see ProofModels).
        guard let manifest = arg("--model").map({ catalog.model($0) }) ?? ProofModels.speech(catalog) else { log("FAIL unknown model \(arg("--model") ?? "-")"); return 1 }
        guard shelf.isAnyVariantDownloaded(manifest) else { log("FAIL not downloaded: \(manifest.name)"); return 1 }
        let choice = ProofModels.choice(manifest, shelf: shelf)
        let voice: VoiceSelection = arg("--voice").map { .preset($0) } ?? (manifest.presetVoices.isEmpty ? .automatic : .preset(manifest.presetVoices[0].id))

        // Run 1: perform.
        let script = "Welcome to Encore. [pause 0.4s] This line was performed by the Studio, from inside the app."
        model.debugSet(choice: choice, voice: voice, script: script,
                       parameters: manifest.parameters.contains { $0.key == "speed" } ? ["speed": .double(1.1)] : [:])
        model.post.normalizeLoudness = true
        if let reason = model.blockedReason { log("FAIL blocked: \(reason)"); return 1 }
        log("plan: \(model.plan?.chunks.count ?? 0) chunks, tags \(model.plan?.parsed.tags.map(\.text) ?? []); chunk text: \(model.plan?.chunks.map(\.text) ?? [])")
        log("perform() with \(manifest.name) (\(choice.variantID ?? "-")), voice \(voice)")
        model.perform()
        await watch(model)
        guard case .finished(let elapsed)? = model.runner.lastOutcome else {
            log("FAIL outcome \(String(describing: model.runner.lastOutcome)), error: \(model.runner.error.map { ErrorPresentation($0)?.title ?? "\($0)" } ?? "none") \(model.runner.error.map { "\($0)" } ?? "")")
            return 1
        }
        log("finished in \(String(format: "%.2f", elapsed)) s")
        // The takes list is fed by a history observation, as on screen.
        for _ in 0..<40 where model.takes.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        guard let take = model.takes.first?.generation else { log("FAIL no take in the takes list"); return 1 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: (try? encoder.encode(take)) ?? Data(), as: UTF8.self))
        let size = (try? fm.attributesOfItem(atPath: take.audioPath)[.size] as? Int) ?? 0
        log("take: \(model.takes.count) in list, new this session: \(model.sessionTakeIDs.contains(take.id)), file \(size) bytes, \(String(format: "%.2f", take.duration)) s @ \(Int(take.sampleRate)) Hz")
        if let probe = try? await AudioReader.probe(take.audioURL) { log("probe: \(String(format: "%.2f", probe.duration)) s") }

        // Run 2: cancel mid-generation.
        let long = Array(repeating: "The house lights dim, and a single spot finds the center of the stage where the voice begins, low and unhurried.", count: 8)
            .joined(separator: " ")
        model.debugSet(choice: choice, voice: voice, script: long)
        log("perform() long script: \(model.plan?.chunks.count ?? 0) chunks; will cancel once generation is under way")
        model.perform()
        var canceled = false
        for _ in 0..<2400 {
            if model.runner.phase == .idle { break }
            if !canceled, let stage = model.runner.stage, stage.hasPrefix("Generating"), (model.runner.progress ?? 0) > 0.05 {
                log("cancel() at stage “\(stage)”, progress \(String(format: "%.2f", model.runner.progress ?? 0))")
                model.cancel()
                canceled = true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await model.runner.waitUntilIdle()
        await runtime.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(300))
        let count = (try? await history.count(HistoryQuery(kinds: [.speech]))) ?? -1
        let leftovers = (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []
        let audioFiles = (try? fm.contentsOfDirectory(atPath: history.audioDirectory.path))?.filter { !$0.hasPrefix(".DS") } ?? []
        log("after cancel: outcome \(String(describing: model.runner.lastOutcome)), error \(model.runner.error.map { "\($0)" } ?? "none"), history \(count), audio files \(audioFiles.count), scratch leftovers \(leftovers)")
        let ok = canceled && model.runner.lastOutcome == .canceled && model.runner.error == nil && count == 1
            && audioFiles.count == 1 && leftovers.isEmpty && status.jobs.isEmpty
        log(ok ? "PASS: performed through StudioModel and canceled cleanly" : "FAIL: cancel left something behind")
        return ok ? 0 : 1
    }

    /// Prints stage changes until the runner is idle (accepting a memory warning, as a user could).
    private static func watch(_ model: StudioModel) async {
        var last = ""
        while model.runner.isBusy {
            if case .confirmMemory(let a) = model.runner.phase {
                log("memory warning: \(a.summary) -> runAnyway()")
                model.runner.runAnyway()
            }
            let line = "\(model.runner.phase) · \(model.runner.stage ?? "-")"
            if line != last { log(line + (model.runner.progress.map { String(format: " %.0f%%", $0 * 100) } ?? "")); last = line }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
