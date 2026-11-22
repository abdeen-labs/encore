#if DEBUG
import EncoreCore
import SwiftUI

/// Made-up History and rail-activity states for `--snapshot` (names start with `History-` / `Rail-`). The seed only
/// writes into snapshot mode's throwaway history (a temp folder), with synthesized audio.
///
///     Encore --snapshot <dir> --snapshot-only History-Mixed,History-Detail-Min,Rail-Running
@MainActor
enum HistoryFixtures {
    static var all: [FeatureFixture] {
        let min = FeatureFixture.minimum
        var out: [FeatureFixture] = []
        func add(_ name: String, minToo: Bool = true, _ configure: @escaping @MainActor (HistoryModel, Seeded) -> Void) {
            out.append(fixture(name, size: nil, configure))
            if minToo { out.append(fixture(name + "-Min", size: min, configure)) }
        }
        for (name, size) in [("History-Empty", nil), ("History-Empty-Min", min)] as [(String, CGSize?)] {
            out.append(FeatureFixture(name: name, section: .history, size: size, prepare: { _ in .init() }, seed: { deps in
                let db = deps.service.history
                if let old = try? await db.fetch(limit: 100_000) { try? await db.delete(old.map(\.id)) }
                await deps.screenModel("History") { HistoryModel(deps: deps) }.waitForResults()
            }))
        }
        add("History-Mixed") { _, _ in }
        add("History-Search") { m, _ in m.search = "captain" }
        add("History-Filtered") { m, _ in m.kind = .speech; m.favoritesOnly = false; m.modelID = "chatterbox-turbo"; m.date = .week }
        add("History-Detail") { m, s in m.focusedID = s.detailTake }
        add("History-Transcript") { m, s in m.focusedID = s.transcript; m.search = "lighting" }
        out.append(fixture("History-Detail-Tall", size: CGSize(width: 1180, height: 1500)) { m, s in m.focusedID = s.detailTake })
        out.append(fixture("History-Transcript-Tall", size: CGSize(width: 1180, height: 1300)) { m, s in m.focusedID = s.transcript })
        add("History-Select") { m, s in m.isSelecting = true; m.selection = Set(s.selected) }
        out.append(FeatureFixture(name: "History-Delete", section: .history, size: CGSize(width: 520, height: 400),
                                  prepare: { _ in .init() },
                                  sheet: { deps, _ in
                                      AnyView(HistoryDeleteSheet(model: deps.screenModel("History") { HistoryModel(deps: deps) })
                                        .environment(deps.toasts))
                                  },
                                  seed: { deps in
                                      let s = await seed(deps)
                                      let m = deps.screenModel("History") { HistoryModel(deps: deps) }
                                      await m.waitForResults()
                                      m.requestDelete(s.selected)
                                  }))
        out.append(FeatureFixture(name: "History-Delete-One", section: .history, size: CGSize(width: 520, height: 330),
                                  prepare: { _ in .init() },
                                  sheet: { deps, _ in
                                      AnyView(HistoryDeleteSheet(model: deps.screenModel("History") { HistoryModel(deps: deps) })
                                        .environment(deps.toasts))
                                  },
                                  seed: { deps in
                                      let s = await seed(deps)
                                      let m = deps.screenModel("History") { HistoryModel(deps: deps) }
                                      await m.waitForResults()
                                      m.requestDelete([s.detailTake])
                                  }))
        // An MP3 export part-way through: the progress card over the screen.
        for (name, size) in [("History-Exporting", nil), ("History-Exporting-Min", min)] as [(String, CGSize?)] {
            out.append(FeatureFixture(name: name, section: .history, size: size, prepare: { deps in
                deps.exports.debugShow("Harbor at dusk, take 3.mp3", fraction: 0.42)
                return .init()
            }, seed: { deps in
                let s = await seed(deps)
                let m = deps.screenModel("History") { HistoryModel(deps: deps) }
                m.focusedID = s.detailTake
                await m.waitForResults()
            }))
        }
        // The rail's activity card, over a populated History.
        for (name, size) in [("Rail-Idle", nil), ("Rail-Running", nil), ("Rail-Queued", nil), ("Rail-Running-Min", min), ("Rail-Queued-Min", min)] as [(String, CGSize?)] {
            out.append(FeatureFixture(name: name, section: .history, size: size, prepare: { deps in
                if name != "Rail-Idle" { jobs(deps, queued: name.hasPrefix("Rail-Queued")) }
                return .init()
            }, seed: { deps in
                _ = await seed(deps)
                await deps.screenModel("History") { HistoryModel(deps: deps) }.waitForResults()
            }))
        }
        return out
    }

    private static func fixture(_ name: String, size: CGSize?, _ configure: @escaping @MainActor (HistoryModel, Seeded) -> Void) -> FeatureFixture {
        FeatureFixture(name: name, section: .history, size: size, prepare: { _ in .init() }, seed: { deps in
            let s = await seed(deps)
            let m = deps.screenModel("History") { HistoryModel(deps: deps) }
            configure(m, s)
            await m.waitForResults()
        })
    }

    struct Seeded { var detailTake: UUID; var transcript: UUID; var selected: [UUID] }

    // MARK: Seed

    static func seed(_ deps: AppDependencies) async -> Seeded {
        let db = deps.service.history
        // Snapshot targets share one temporary history per run: start each fixture from nothing.
        if let old = try? await db.fetch(limit: 100_000) { try? await db.delete(old.map(\.id)) }
        let now = Date()
        let captain = UUID(), mira = UUID()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let calendar = Calendar.current
        // Keep "today" items on today even just after midnight.
        let sinceMidnight = now.timeIntervalSince(calendar.startOfDay(for: now)) / 60
        func today(_ minutes: Double) -> Date { ago(Swift.min(minutes, Swift.max(0.5, sinceMidnight * minutes / 120))) }

        var post = PostProcessingOptions()
        post.removeSilence = true
        post.maxSilenceSeconds = 0.5

        struct Take {
            var kind: GenerationRecord.Kind; var title: String; var text: String; var model: String; var variant: String?
            var voice: String?; var voiceID: UUID?; var params: ParamValues = [:]; var language: String?; var instruct: String?
            var post: PostProcessingOptions? = PostProcessingOptions(); var runtime: EngineRuntime = .mlxSwift
            var seconds: Double; var elapsed: Double; var at: Date; var favorite = false; var pitch: Double = 140
        }
        let takes: [Take] = [
            Take(kind: .speech, title: "Ladies and gentlemen, tonight",
                 text: "Ladies and gentlemen, tonight [pause 0.5s] the role of the Captain will be played by a voice you have never heard before. Please take your seats.",
                 model: "qwen3-tts-customvoice", variant: "1.7b-8bit", voice: "Ryan", params: ["temperature": .double(0.95), "seed": .int(424_242)],
                 language: "english", instruct: "Grand and theatrical, savoring every word", post: post,
                 seconds: 9.4, elapsed: 6.2, at: today(12), favorite: true, pitch: 112),
            Take(kind: .speech, title: "The house lights dim", text: "The house lights dim. A single spot finds the center of the stage.",
                 model: "zonos3-mini", variant: "bf16", voice: "Imogen", params: ["speed": .double(1.1)], language: "en",
                 seconds: 4.2, elapsed: 0.9, at: today(40), pitch: 190),
            Take(kind: .conversation, title: "Act two, scene one",
                 text: "Captain Reyes: Who goes there?\nMira: Only the understudy, Captain.\nCaptain Reyes: Then step into the light.",
                 model: "qwen3-tts-customvoice", variant: "1.7b-8bit", voice: "Captain Reyes, Mira", language: "english",
                 seconds: 11.8, elapsed: 9.1, at: today(95), pitch: 130),
            Take(kind: .voiceChange, title: "Voice change · rehearsal take 3", text: "rehearsal take 3.wav", model: "chatterbox-vc",
                 variant: "multilingual-v3", voice: "Mira", voiceID: mira, runtime: .python, seconds: 7.5, elapsed: 5.4, at: ago(60 * 26), pitch: 205),
            Take(kind: .voiceDesign, title: "Mira", text: "Hello there. I wasn't expecting you so soon.", model: "qwen3-tts-voicedesign",
                 variant: "1.7b-8bit", voice: "Mira", voiceID: mira, params: ["temperature": .double(0.9)], language: "english",
                 instruct: "A bright young woman, quick and amused, a little breathless", post: nil, seconds: 3.6, elapsed: 3.9,
                 at: ago(60 * 27), favorite: true, pitch: 215),
            Take(kind: .speech, title: "Chapter one. It was raining", text: "Chapter one. It was raining in the way it only rains in port towns: sideways, and with intent.",
                 model: "qwen3-tts-base", variant: "1.7b-8bit", voice: "Captain Reyes", voiceID: captain, language: "english",
                 seconds: 6.1, elapsed: 4.4, at: ago(60 * 29), pitch: 105),
            Take(kind: .speech, title: "Hello there, I'm Mira", text: "Hello there, I'm Mira. [laugh] I wasn't expecting you so soon.",
                 model: "chatterbox-turbo", variant: "8bit", voice: "Mira", voiceID: mira, params: ["temperature": .double(0.85)],
                 seconds: 3.6, elapsed: 1.8, at: ago(60 * 24 * 3), pitch: 210),
            Take(kind: .speech, title: "Steady as she goes", text: "Steady as she goes, Captain. The harbor lights are on our port side.",
                 model: "chatterbox-turbo", variant: "8bit", voice: "Captain Reyes", voiceID: captain, seconds: 5.0, elapsed: 2.4,
                 at: ago(60 * 24 * 3 + 30), favorite: true, pitch: 100),
            Take(kind: .speech, title: "Welcome to the Encore stage", text: "Welcome to the Encore stage. Tonight's program runs for ninety minutes, with one interval.",
                 model: "zonos3-mini", variant: "bf16", voice: "Imogen", language: "en", seconds: 5.6, elapsed: 1.1, at: ago(60 * 24 * 5), pitch: 185),
            Take(kind: .speech, title: "Good evening and welcome", text: "(A warm, unhurried narrator) Good evening, and welcome back to the archive.",
                 model: "voxcpm2", variant: "8bit", voice: nil, instruct: "A warm, unhurried narrator", seconds: 4.8, elapsed: 4.3,
                 at: ago(60 * 24 * 34), pitch: 120),
        ]

        var ids: [UUID] = []
        for (i, t) in takes.enumerated() {
            let id = UUID()
            let url = db.newAudioURL(id: id)
            try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: t.seconds, seed: 30 + i, pitch: t.pitch), to: url)
            let m = deps.catalog.model(t.model)
            let record = GenerationRecord(id: id, kind: t.kind, title: t.title, text: t.text, modelID: t.model, modelName: m?.name ?? t.model,
                                          voiceName: t.voice, voiceID: t.voiceID,
                                          parameters: (m?.defaultParameters ?? [:]).merging(t.params) { $1 },
                                          audioPath: url.path, duration: t.seconds, sampleRate: 24_000, createdAt: t.at, elapsed: t.elapsed,
                                          favorite: t.favorite, variantID: t.variant, language: t.language, instruct: t.instruct,
                                          post: t.post, runtime: t.runtime)
            try? await db.insert(record)
            ids.append(id)
        }

        let interview = Transcript(text: "", language: "en", duration: 192, segments: [
            .init(id: 0, start: 0, end: 6.2, text: "Thanks for having me. I've wanted to talk about this production for a long time."),
            .init(id: 1, start: 6.2, end: 14.8, text: "The lighting was the hardest part. We rebuilt the rig twice before the first preview."),
            .init(id: 2, start: 14.8, end: 22.5, text: "Every cue had to land on a breath, so the actors and the board operator rehearsed together."),
            .init(id: 3, start: 22.5, end: 31.0, text: "By opening night the lighting felt like another member of the cast."),
            .init(id: 4, start: 31.0, end: 38.4, text: "And the audience noticed. People wrote to us about the final blackout."),
        ])
        let transcripts: [TranscriptionRecord] = [
            TranscriptionRecord(sourceName: "Interview with the director.m4a", sourcePath: "/Users/example/Movies/Interview with the director.m4a",
                                modelID: "whisper-large-v3-turbo", modelName: deps.catalog.model("whisper-large-v3-turbo")?.name ?? "Whisper",
                                transcript: interview, createdAt: today(70), elapsed: 11.4, variantID: "fp16", language: nil,
                                timestamps: .word, parameters: ["task": .string("transcribe"), "temperature": .double(0)], runtime: .python),
            TranscriptionRecord(sourceName: "Podcast episode 12.mp3", sourcePath: "/Users/example/Music/Podcast episode 12.mp3",
                                modelID: "parakeet-tdt-v3", modelName: deps.catalog.model("parakeet-tdt-v3")?.name ?? "Parakeet",
                                transcript: Transcript(text: "Welcome back to Behind the Curtain, the podcast about the people you never see on stage. This week: stage managers.",
                                                       language: "en", duration: 1_874, segments: [
                                                        .init(id: 0, start: 0, end: 7.5, text: "Welcome back to Behind the Curtain, the podcast about the people you never see on stage."),
                                                        .init(id: 1, start: 7.5, end: 10.1, text: "This week: stage managers."),
                                                       ]),
                                createdAt: ago(60 * 24 * 4), elapsed: 38, variantID: "0.6b", timestamps: .segment, runtime: .mlxSwift),
        ]
        for t in transcripts { try? await db.insert(t) }
        return Seeded(detailTake: ids[0], transcript: transcripts[0].id, selected: [ids[1], ids[2], transcripts[0].id])
    }

    // MARK: Rail jobs

    /// One job running (and, with `queued`, two more waiting).
    static func jobs(_ deps: AppDependencies, queued: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        var jobs: [[String: Any]] = [
            ["id": UUID().uuidString, "kind": "speech", "title": "Chapter two. The storm broke over the harbor", "modelID": "qwen3-tts-base",
             "modelName": "Qwen3-TTS", "state": "running", "stage": "Generating 3 of 7", "progress": 0.42, "runtime": "mlxSwift",
             "enqueuedAt": now - 20, "startedAt": now - 18],
        ]
        if queued {
            jobs.append(["id": UUID().uuidString, "kind": "transcription", "title": "Interview with the director.m4a",
                         "modelID": "whisper-large-v3-turbo", "modelName": "Whisper large-v3 turbo", "state": "queued", "enqueuedAt": now - 6])
            jobs.append(["id": UUID().uuidString, "kind": "voiceConversion", "title": "Voice change · rehearsal take 4",
                         "modelID": "chatterbox-vc", "modelName": "Chatterbox Voice Changer", "state": "queued", "enqueuedAt": now - 2])
        }
        let json: [String: Any] = [
            "version": 1_000_001, "jobs": jobs, "recentUnloads": [], "loaded": [],
            "memory": ["physicalBytes": 51_539_607_552, "availableBytes": 33_700_000_000, "pressure": "normal"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let snapshot = try? JSONDecoder().decode(RuntimeSnapshot.self, from: data) {
            deps.runtimeStatus.apply(snapshot)
        }
    }
}
#endif
