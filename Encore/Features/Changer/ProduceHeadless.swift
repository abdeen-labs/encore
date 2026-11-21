#if DEBUG
import EncoreCore
import EncoreMLX
import Foundation

/// DEBUG only: drives the Changer, Conversations and Transcribe screens' own models through real runs inside the
/// app process, with no window and no audio out loud:
///
///     HF_HUB_OFFLINE=1 ENCORE_PYTHON_HOME=… Encore.app/Contents/MacOS/Encore --produce-headless changer|conversations|transcribe|all [--keep]
///
/// Stores live in a temporary folder (deleted at the end unless --keep); the real Hugging Face cache is read only.
/// Everything runs on the smallest models that can do it (see ProofModels). Exit status 0 when every check passes.
@MainActor
enum ProduceHeadless {
    static var isRequested: Bool { CommandLine.arguments.contains("--produce-headless") }

    static func run() -> Never {
        Task { @MainActor in exit(await go()) }
        dispatchMain()
    }

    private static func go() async -> Int32 {
        let what = arg("--produce-headless") ?? "all"
        let h: Harness
        do { h = try await Harness() } catch { log("FAIL setup: \(error)"); return 1 }
        var ok = true
        if what == "changer" || what == "all" { ok = await ChangerHeadless.run(h) && ok }
        if what == "conversations" || what == "all" { ok = await ConversationsHeadless.run(h) && ok }
        if what == "transcribe" || what == "all" { ok = await TranscribeHeadless.run(h) && ok }
        // Unload everything and stop the Python helper, so no encore_helper process outlives the run.
        await h.runtime.unloadAll()
        await h.python.shutdown()
        h.cleanUp()
        log(ok ? "ALL PASS (\(what))" : "SOME CHECKS FAILED (\(what))")
        return ok ? 0 : 1
    }

    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    private static let start = Date()

    static func log(_ s: String) {
        print("[\(String(format: "%7.2f", Date().timeIntervalSince(start)))] \(s)")
        fflush(stdout)
    }

    @discardableResult
    static func check(_ condition: Bool, _ what: String) -> Bool {
        log((condition ? "  ok   " : "  FAIL ") + what)
        return condition
    }

    /// Prints stage changes until the runner is idle (accepting a memory warning, as a user could).
    static func watch(_ runner: JobRunner, label: String, onStage: ((String) -> Void)? = nil) async {
        var last = ""
        while runner.isBusy {
            if case .confirmMemory(let a) = runner.phase {
                log("\(label): memory warning: \(a.summary) -> runAnyway()")
                runner.runAnyway()
            }
            let line = runner.stage ?? "-"
            if line != last {
                log("\(label): \(line)" + (runner.progress.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
                onStage?(line)
                last = line
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await runner.waitUntilIdle()
    }

    /// Everything a screen model needs, on temporary stores.
    @MainActor
    final class Harness {
        let root: URL
        let suite: String
        let settings: AppSettings
        let history: HistoryDatabase
        let voices: VoiceLibrary
        let pronunciations: PronunciationStore
        let catalog: ModelCatalog
        let status: RuntimeStatus
        let runtime: ModelRuntime
        let service: EncoreService
        let shelf: ModelShelf
        let python = PythonBackend()
        let media: URL

        init() async throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("EncoreProduceHeadless-\(ProcessInfo.processInfo.processIdentifier)")
            media = root.appendingPathComponent("Media")
            try fm.createDirectory(at: media, withIntermediateDirectories: true)
            let throwaway = ThrowawayDefaults.make("EncoreProduceHeadless")
            suite = throwaway.suite
            settings = AppSettings(defaults: throwaway.defaults, key: "settings")
            history = try HistoryDatabase(directory: root.appendingPathComponent("History"))
            voices = VoiceLibrary(directory: root.appendingPathComponent("Voices"), deletesToTrash: false)
            pronunciations = PronunciationStore(directory: root)
            (catalog, _) = ModelCatalog.bundled()
            status = RuntimeStatus()
            runtime = ModelRuntime(idleMinutes: { 0 }, status: status, autoSweep: false)
            service = EncoreService(catalog: catalog, history: history, voices: voices, pronunciations: pronunciations,
                                    settings: settings, backends: [MLXSwiftBackend(), python], runtime: runtime,
                                    scratchDirectory: root.appendingPathComponent("Scratch"))
            shelf = ModelShelf(service: service, downloads: ModelDownloadCenter(catalog: catalog))
            await shelf.waitForScan()
            ProduceHeadless.log("data root: \(root.path) (temporary); \(shelf.downloaded.count) variants on disk; python: \(PythonRuntime.locate())")
            // Every screen model here starts on the smallest model that can do its job (see ProofModels).
            let missing = ProofModels.seed(settings, catalog: catalog, shelf: shelf, features: [.conversation, .voiceChange, .transcription])
            guard missing.isEmpty else { throw ServiceError.generationFailed("Not downloaded: \(missing.joined(separator: ", "))") }
        }

        func cleanUp() {
            let fm = FileManager.default
            if !CommandLine.arguments.contains("--keep") { try? fm.removeItem(at: root) }
            ThrowawayDefaults.remove(suite)
        }

        /// Speaks `text` with preset voice number `voice` of the smallest model that has several, and returns a copy
        /// of the WAV in the media folder (the take itself stays in the temp history).
        func speak(_ text: String, voice: Int, name: String) async throws -> URL {
            guard let m = ProofModels.speakers(catalog) else { throw ServiceError.generationFailed("no model with preset voices") }
            var r = SpeechRequest(modelID: m.id, text: text)
            r.variantID = ProofModels.choice(m, shelf: shelf).variantID
            r.voice = ProofModels.voice(voice, of: m)
            var record: GenerationRecord?
            for try await event in service.speak(r) {
                if case .finished(let rec) = event { record = rec }
            }
            guard let record else { throw ServiceError.generationFailed("no record") }
            let url = media.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: record.audioURL, to: url)
            return url
        }

        /// Transcribes without saving (the reference-transcription path), for checking what audio says.
        func hear(_ url: URL) async -> String {
            (try? await service.transcribeReference(url, modelID: ProofModels.transcription(catalog)?.id).text) ?? "(transcription failed)"
        }
    }

    // MARK: Measuring

    /// Words two transcripts share, as a fraction of the reference's words.
    static func overlap(_ reference: String, _ heard: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 1 }
        }
        let ref = words(reference), got = Set(words(heard))
        guard !ref.isEmpty else { return 0 }
        return Double(ref.filter(got.contains).count) / Double(ref.count)
    }

    /// Median fundamental frequency of the voiced frames (autocorrelation, 70–400 Hz), as a rough "whose voice" measure.
    static func medianPitch(_ url: URL) async -> Double? {
        guard let b = try? await AudioReader.read(url, sampleRate: 16_000) else { return nil }
        let x = b.samples, rate = 16_000.0, frame = 640, hop = 320
        let minLag = Int(rate / 400), maxLag = Int(rate / 70)
        var pitches: [Double] = []
        var i = 0
        while i + frame + maxLag < x.count {
            var energy: Float = 0
            for k in 0..<frame { energy += x[i + k] * x[i + k] }
            if energy / Float(frame) > 1e-4 {
                var best = 0.0, bestLag = 0
                for lag in minLag...maxLag {
                    var s: Float = 0
                    for k in 0..<frame { s += x[i + k] * x[i + k + lag] }
                    let r = Double(s / energy)
                    if r > best { best = r; bestLag = lag }
                }
                if best > 0.5, bestLag > 0 { pitches.append(rate / Double(bestLag)) }
            }
            i += hop
        }
        guard !pitches.isEmpty else { return nil }
        return pitches.sorted()[pitches.count / 2]
    }
}
#endif
