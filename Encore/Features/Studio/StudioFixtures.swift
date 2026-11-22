#if DEBUG
import EncoreCore
import SwiftUI

/// Populated snapshot states, DEBUG only. Snapshot mode already runs on throwaway stores in a temp folder with an
/// empty model cache; `--fixtures` fills those stores (voices, takes with synthesized WAVs, pronunciations, a
/// preset, a few models marked downloaded) and `--studio-fixture <state>` puts the Studio in a state:
///
///     Encore --snapshot <dir> --snapshot-only Studio --fixtures --studio-fixture ready [--snapshot-size 940x600]
///
/// States: ready, advanced, running, takes, error, memory, notDownloaded, pronunciations, modelPicker, voicePicker,
/// runtimeFallback.
/// Nothing here can reach the user's data: it only runs in snapshot mode, whose stores are temporary.
@MainActor
enum StudioFixtures {
    static var isRequested: Bool { CommandLine.arguments.contains("--fixtures") && SnapshotConfig(arguments: CommandLine.arguments) != nil }

    static var state: String? {
        let args = CommandLine.arguments
        guard isRequested, let i = args.firstIndex(of: "--studio-fixture"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Seeds the snapshot's temporary stores and configures the Studio model. Called by the snapshot runner.
    static func prepare(_ deps: AppDependencies) async {
        guard isRequested else { return }
        let ids = await seed(deps)
        let shelf = deps.modelShelf
        shelf.rescan()
        await shelf.waitForScan()
        for (id, runtime) in ["chatterbox-turbo": EngineRuntime.mlxSwift, "qwen3-tts-base": .mlxSwift,
                              "voxcpm2": .python, "omnivoice": .mlxSwift, "chatterbox-multilingual": .python,
                              "qwen3-tts-customvoice": .mlxSwift, "qwen3-tts-voicedesign": .mlxSwift, "orpheus": .mlxSwift,
                              "soprano": .mlxSwift, "zonos3-mini": .mlxSwift] {
            shelf.runtimeOverrides[id] = .runs(runtime)
        }
        let model = deps.screenModel("Studio") { StudioModel(deps: deps) }
        await model.prepare()
        configure(model, deps: deps, ids: ids)
        // Let the takes observation deliver.
        try? await Task.sleep(for: .milliseconds(300))
    }

    struct Seeded { var captain: UUID; var mira: UUID; var takes: [UUID] }

    // MARK: Seeding

    private static func seed(_ deps: AppDependencies) async -> Seeded {
        let catalog = deps.catalog
        // Models "on disk": a snapshot folder with one file per repo is enough for the service to accept them.
        let layout = deps.service.hub.layout
        let commit = String(repeating: "f1", count: 20)
        let downloaded: [(String, String?)] = [("zonos3-mini", nil), ("chatterbox-turbo", nil), ("qwen3-tts-base", nil),
                                               ("voxcpm2", nil), ("omnivoice", nil), ("chatterbox-multilingual", nil)]
        for (id, variantID) in downloaded {
            guard let m = catalog.model(id) else { continue }
            let v = m.variant(variantID)
            for repo in v.allRepos {
                let ref = layout.refFile(repo, ref: "main")
                let snap = layout.snapshotDirectory(repo, commit: commit)
                try? FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
                try? Data(commit.utf8).write(to: ref)
                try? Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
            }
        }
        // VoxCPM2: also its bf16 variant, for the memory warning.
        if let m = catalog.model("voxcpm2"), let bf16 = m.variants.first(where: { $0.label.lowercased().contains("bf16") }) {
            for repo in bf16.allRepos {
                let snap = layout.snapshotDirectory(repo, commit: commit)
                try? FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: layout.refFile(repo, ref: "main").deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(commit.utf8).write(to: layout.refFile(repo, ref: "main"))
                try? Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
            }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("EncoreFixtureAudio-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Voices.
        let captain = Voice(name: "Captain Reyes", tags: ["narration", "warm", "low"], origin: .cloned,
                            transcript: "Steady as she goes.", language: "en", duration: 8.4,
                            consentConfirmedAt: Date())
        let mira = Voice(name: "Mira", tags: ["bright", "young"], origin: .designed, transcript: "Hello there.",
                         designPrompt: "A bright young woman, quick and amused", duration: 6.1)
        let tom = Voice(name: "Old Tom", tags: ["gravel"], origin: .imported, transcript: "Back in my day.", duration: 11.2)
        var captainID = captain.id, miraID = mira.id
        for (i, v) in [captain, mira, tom].enumerated() {
            let url = tmp.appendingPathComponent("voice-\(i).wav")
            try? AudioExporter.writeWAV(speechLike(seconds: v.duration, seed: i + 1, pitch: [110, 210, 95][i]), to: url)
            if let saved = try? await deps.voices.add(v, referenceAudio: url, move: true) {
                if i == 0 { captainID = saved.id }
                if i == 1 { miraID = saved.id }
            }
        }

        // Takes: real WAVs in the temp history.
        let takes: [(String, String, String, String?, Double, Double, Bool)] = [
            ("The house lights dim", "The house lights dim. A single spot finds the center of the stage.", "zonos3-mini", "Imogen", 4.2, 0.9, false),
            ("Ladies and gentlemen, tonight", "Ladies and gentlemen, tonight [pause 0.5s] the role of the Captain will be played by…", "chatterbox-turbo", "Captain Reyes", 6.8, 3.1, true),
            ("Chapter one. It was raining", "Chapter one. It was raining in the way it only rains in port towns.", "qwen3-tts-base", "Captain Reyes", 5.1, 4.4, false),
            ("Hello there, I'm Mira", "Hello there, I'm Mira. [laugh] I wasn't expecting you so soon.", "chatterbox-turbo", "Mira", 3.6, 1.8, false),
        ]
        var takeIDs: [UUID] = []
        for (i, t) in takes.enumerated() {
            let id = UUID()
            let url = deps.service.history.newAudioURL(id: id)
            try? AudioExporter.writeWAV(speechLike(seconds: t.4, seed: 10 + i, pitch: [180, 105, 115, 205][i]), to: url)
            let m = catalog.model(t.2)
            let record = GenerationRecord(id: id, kind: .speech, title: t.0, text: t.1, modelID: t.2, modelName: m?.name ?? t.2,
                                          voiceName: t.3, voiceID: t.3 == "Captain Reyes" ? captainID : (t.3 == "Mira" ? miraID : nil),
                                          parameters: m?.defaultParameters ?? [:], audioPath: url.path, duration: t.4, sampleRate: 24_000,
                                          createdAt: Date().addingTimeInterval(-Double(takes.count - i) * 900), elapsed: t.5, favorite: t.6)
            try? await deps.service.history.insert(record)
            takeIDs.append(id)
        }

        try? deps.pronunciations.save(PronunciationEntry(term: "Nguyen", replacement: "win"))
        try? deps.pronunciations.save(PronunciationEntry(term: "GIF", replacement: "jif", caseSensitive: true))
        try? deps.pronunciations.save(PronunciationEntry(term: "Encore", replacement: "on-core", enabled: false))
        try? deps.pronunciations.save(PronunciationEntry(term: "Reyes", replacement: "ray-ess"))
        try? deps.presets.save(Preset(name: "Warm narration", modelID: "chatterbox-turbo", parameters: ["temperature": .double(0.95)]))
        try? FileManager.default.removeItem(at: tmp)
        return Seeded(captain: captainID, mira: miraID, takes: takeIDs.reversed())
    }

    /// A few seconds of something waveform-shaped: voiced syllables with a pitch contour, breath noise and pauses.
    static func speechLike(seconds: Double, seed: Int, pitch: Double, rate: Double = 24_000) -> AudioBuffer {
        let n = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: n)
        var rng = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        func noise() -> Float {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Float(Int64(bitPattern: rng % 2000) - 1000) / 1000
        }
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let syllable = max(0, sin(2 * .pi * (3.6 + 0.4 * sin(Double(seed) + t)) * t))
            let phrase = sin(.pi * min(1, (t.truncatingRemainder(dividingBy: 2.3)) / 1.9))
            let gate = (t.truncatingRemainder(dividingBy: 2.3)) < 1.9 ? 1.0 : 0.0
            let f0 = pitch * (1 + 0.12 * sin(2 * .pi * 0.7 * t + Double(seed)))
            phase += 2 * .pi * f0 / rate
            let voiced = sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)
            let env = pow(syllable, 1.6) * phrase * gate
            samples[i] = Float(0.28 * env * voiced) + 0.02 * Float(env) * noise()
        }
        return AudioBuffer(samples: samples, sampleRate: rate)
    }

    // MARK: States

    private static func configure(_ model: StudioModel, deps: AppDependencies, ids: Seeded) {
        let tagged = "Ladies and gentlemen, [pause 0.6s] tonight's performance begins. [laugh] Please silence your phones.\n\n[voice: Mira] Wait, has anyone seen the Captain? [whisper] He was here a minute ago…\n\n[voice: Captain Reyes] I'm right behind you, Dr. Nguyen."
        let turbo = ModelChoice(modelID: "chatterbox-turbo", variantID: deps.catalog.model("chatterbox-turbo")?.defaultVariant.id)
        let zonos = ModelChoice(modelID: "zonos3-mini", variantID: "bf16")
        let narrationScript = "The house lights dim. A single spot finds the center of the stage, and the voice begins: low, unhurried, certain of its audience. [pause 1s] This is the line we will perform."
        model.wingsTab = .tuning
        switch state {
        case "ready", nil:
            model.debugSet(choice: turbo, voice: .library(ids.captain), script: tagged, parameters: ["temperature": .double(0.95)])
        case "advanced":
            model.debugSet(choice: turbo, voice: .library(ids.captain), script: tagged,
                           parameters: ["temperature": .double(0.95), "top_p": .double(0.9), "seed": .int(424_242)])
            model.showAdvanced = true
        case "running":
            model.debugSet(choice: zonos, voice: .preset("imogen"), script: narrationScript, parameters: ["speed": .double(1.1)])
            model.wingsTab = .takes
            model.runner.debugShow(.running, identity: .init(kind: .speech, modelID: "zonos3-mini", modelName: "Zonos3 Mini"),
                                   stage: "Generating 2 of 3", progress: 0.46, startedAt: Date().addingTimeInterval(-4))
        case "takes":
            model.debugSet(choice: zonos, voice: .preset("imogen"), script: narrationScript)
            model.wingsTab = .takes
            if let first = ids.takes.first { model.debugMarkSessionTake(first) }
            model.runner.debugShow(.idle, identity: nil, lastOutcome: .finished(elapsed: 1.4))
        case "error":
            model.debugSet(choice: ModelChoice(modelID: "chatterbox-multilingual"), voice: .library(ids.mira),
                           script: "Hello there. I wasn't expecting you so soon.")
            model.runner.debugShow(.idle, identity: nil,
                                   error: ServiceError.backendNeedsSetup(runtime: .python, message: "The Python runtime isn't installed yet"))
        case "memory":
            let m = deps.catalog.model("voxcpm2")
            let bf16 = m?.variants.first { $0.label.lowercased().contains("bf16") }
            model.debugSet(choice: ModelChoice(modelID: "voxcpm2", variantID: bf16?.id), voice: .library(ids.captain), script: narrationScript,
                           instruct: "")
            model.runner.debugShow(.confirmMemory(fakeAssessment(m, bf16)), identity: .init(kind: .speech, modelID: "voxcpm2", modelName: "VoxCPM2"))
        case "notDownloaded":
            model.debugSet(choice: ModelChoice(modelID: "qwen3-tts-voicedesign"), script: narrationScript,
                           instruct: "A warm, raspy older man, slow and deliberate")
        case "pronunciations":
            model.debugSet(choice: zonos, voice: .preset("imogen"), script: narrationScript)
            model.wingsTab = .takes
        case "runtimeFallback":
            // VoxCPM2 runs best in the Python helper; here it isn't set up, so Automatic runs it natively.
            deps.modelShelf.runtimeOverrides["voxcpm2"] = .runs(.mlxSwift)
            model.debugSet(choice: ModelChoice(modelID: "voxcpm2"), voice: .library(ids.captain), script: narrationScript, instruct: "")
        case "modelPicker", "voicePicker":
            model.debugSet(choice: turbo, voice: .library(ids.captain), script: tagged)
        default:
            model.debugSet(choice: turbo, script: tagged)
        }
    }

    /// A "tight" verdict for a 5 GB model on a busy Mac (MemoryAssessment has no public init; it's Codable).
    private static func fakeAssessment(_ m: ModelManifest?, _ v: ModelVariant?) -> MemoryAssessment {
        let gb: Int64 = 1_000_000_000
        let json: [String: Any] = [
            "verdict": "tight", "modelID": m?.id ?? "voxcpm2", "variantID": v?.id ?? "bf16",
            "requiredBytes": v?.memoryBytes ?? 5 * gb,
            "memory": ["physicalBytes": 48 * gb, "availableBytes": 4_200_000_000, "pressure": "normal"],
            "loadedBytes": 8 * gb, "evictableBytes": 3 * gb, "budgetBytes": 36 * gb, "headroomBytes": 4_800_000_000,
            "alreadyLoaded": false, "wouldUnload": ["Qwen3-TTS"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(MemoryAssessment.self, from: data)
    }
}
#endif
