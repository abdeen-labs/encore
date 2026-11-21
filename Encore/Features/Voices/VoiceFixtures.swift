#if DEBUG
import EncoreCore
import SwiftUI

/// Snapshot states for the Clone, Voices and Design screens, DEBUG only. They seed snapshot mode's throwaway stores
/// (voices with synthesized clips, a few models marked downloaded) and put the screen's model in a state:
///
///     Encore --snapshot <dir> --snapshot-only Clone --voice-fixture clone-good [--snapshot-size 940x600]
///
/// Clone: clone-empty, clone-record, clone-good, clone-tooLong, clone-tooShort, clone-transcribing, clone-noSTT,
///        clone-consented, clone-saved, clone-wholeFile, clone-wholeFileUsed.
/// Voices: voices-empty, voices-grid, voices-filtered, voices-detail, voices-multi, voices-picked, voices-import
///         (the import consent sheet itself: `--snapshot-only Voices-ImportConsent,Voices-ImportConsent-Ticked,Voices-ImportConsent-One`).
/// Design: design-empty, design-running, design-ready, design-saving, design-kept, design-noModel.
/// Nothing here touches the user's data, a model or the microphone: snapshot stores are temporary, and the
/// recording panel is drawn from made-up state.
@MainActor
enum VoiceFixtures {
    static var state: String? {
        let a = CommandLine.arguments
        guard SnapshotConfig(arguments: a) != nil, let i = a.firstIndex(of: "--voice-fixture"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// Called by the snapshot runner for every target.
    static func prepare(_ deps: AppDependencies) async {
        guard let state else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncoreSnapshot-voicefx-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var models = ["soprano", "qwen3-tts-base", "chatterbox-turbo", "qwen3-tts-voicedesign", "voxcpm2", "whisper-large-v3-turbo"]
        if state == "clone-noSTT" { models.removeAll { $0.hasPrefix("whisper") } }
        if state == "design-noModel" { models.removeAll { $0 == "qwen3-tts-voicedesign" || $0 == "voxcpm2" } }
        markDownloaded(models, deps: deps)
        let shelf = deps.modelShelf
        shelf.rescan()
        await shelf.waitForScan()
        for id in models { shelf.runtimeOverrides[id] = .runs(.mlxSwift) }

        if state.hasPrefix("clone-") { await clone(state, deps: deps, folder: folder) }
        if state.hasPrefix("voices-") { await voices(state, deps: deps, folder: folder) }
        if state.hasPrefix("design-") { await design(state, deps: deps, folder: folder) }
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: Clone

    private static func clone(_ state: String, deps: AppDependencies, folder: URL) async {
        if state != "clone-empty" { await seedVoices(deps, folder: folder, count: 3) }
        let model = deps.screenModel("Clone") { CloneModel(deps: deps) }
        model.autoTranscribe = false
        await model.prepare()
        if state == "clone-record" {
            model.mode = .record
            let levels = (0..<150).map { i -> Float in
                let t = Double(i) / 12
                return Float(max(0.04, min(0.95, 0.45 + 0.35 * sin(t * 2.1) * sin(t * 0.7 + 1) + 0.12 * sin(t * 9))))
            }
            CloneFixtureState.recording = RecordingDisplay(permission: .granted, isRecording: true, elapsed: 7.4, level: -17, levels: levels)
            return
        }
        guard state != "clone-empty" else { return }

        // A long interview: 4 min 12 s of speech-like audio.
        let url = folder.appendingPathComponent("Interview with Ines Varga – full.wav")
        let long = StudioFixtures.speechLike(seconds: 252, seed: 5, pitch: 168)
        try? AudioExporter.writeWAV(long, to: url)
        let source = CloneModel.Source(url: url, name: "Interview with Ines Varga — full.wav", kind: .file, duration: 252,
                                       sampleRate: 24_000, hasVideo: false, fileSize: Int64(long.samples.count * 2 + 44))
        let words = "Honestly, the first time I walked on stage I forgot every single line. So I just started talking to the audience, and they laughed, and that was it — I was hooked."
        switch state {
        case "clone-wholeFile", "clone-wholeFileUsed":
            // A file that's already a good length (12.4 s): the trimmer offers "Use whole file"; once used, it's all selected.
            let shortURL = folder.appendingPathComponent("Ines voice memo.wav")
            let short = StudioFixtures.speechLike(seconds: 12.4, seed: 6, pitch: 168)
            try? AudioExporter.writeWAV(short, to: shortURL)
            let memo = CloneModel.Source(url: shortURL, name: "Ines voice memo.wav", kind: .file, duration: 12.4,
                                         sampleRate: 24_000, hasVideo: false, fileSize: Int64(short.samples.count * 2 + 44))
            let used = state == "clone-wholeFileUsed"
            model.debugSetSource(memo, selection: used ? 0...12.4 : 1.3...11.3)
            if used { model.debugSetTranscript(words, state: .ready(0...12.4, modelName: "Whisper Large v3 Turbo")) }
        case "clone-tooLong":
            model.debugSetSource(source, selection: 58.0...96.4)
        case "clone-tooShort":
            model.debugSetSource(source, selection: 61.2...63.6)
            model.debugSetTranscript("Honestly, the first time", state: .stale, edited: true)
        case "clone-transcribing":
            model.debugSetSource(source, selection: 61.2...72.9)
            model.debugSetTranscript("", state: .transcribing(61.2...72.9))
        case "clone-noSTT":
            model.debugSetSource(source, selection: 61.2...72.9)
            model.debugSetTranscript("", state: .noModel)
        case "clone-consented":
            model.debugSetSource(source, selection: 61.2...72.9)
            model.debugSetTranscript(words, state: .ready(61.2...72.9, modelName: "Whisper Large v3 Turbo"))
            model.name = "Ines Varga"
            model.tags = ["interview", "warm", "storyteller"]
            model.language = "en"
            model.consent = true
        case "clone-saved":
            model.debugSetSource(source, selection: 61.2...72.9)
            let clip = folder.appendingPathComponent("ines.wav")
            try? AudioExporter.writeWAV(AudioEdit.trim(long, to: 61.2...72.9), to: clip)
            let v = Voice(name: "Ines Varga", tags: ["interview", "warm", "storyteller"], origin: .cloned, transcript: words,
                          language: "en", sourceModelID: "qwen3-tts-base", duration: 11.7, consentConfirmedAt: Date())
            if let saved = try? await deps.voices.add(v, referenceAudio: clip, move: true) {
                model.debugSetSaved(saved)
                let take = folder.appendingPathComponent("first-words.wav")
                try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: 6.3, seed: 9, pitch: 172), to: take)
                let record = GenerationRecord(kind: .speech, title: "Ines Varga — first words", text: "Hello…", modelID: "qwen3-tts-base",
                                              modelName: "Qwen3-TTS Base", voiceName: "Ines Varga", voiceID: saved.id,
                                              audioPath: take.path, duration: 6.3, sampleRate: 24_000, elapsed: 3.8)
                model.tryout.debugShow(voice: saved, choice: ModelChoice(modelID: "qwen3-tts-base", variantID: "1.7b-8bit"), result: record)
            }
        default: // clone-good
            model.debugSetSource(source, selection: 61.2...72.9)
            model.debugSetTranscript(words, state: .ready(61.2...72.9, modelName: "Whisper Large v3 Turbo"))
        }
    }

    // MARK: Voices

    private static func voices(_ state: String, deps: AppDependencies, folder: URL) async {
        let model = deps.screenModel("Voices") { VoicesModel(deps: deps) }
        if state == "voices-empty" { return }
        let ids = await seedVoices(deps, folder: folder, count: 7)
        switch state {
        case "voices-filtered":
            model.origin = .cloned
            model.tags = ["narration"]
        case "voices-detail":
            model.focus(ids[0])
        case "voices-multi":
            model.selection = Set(ids.prefix(3))
        case "voices-picked":
            // One card checked with its circle (the batch bar shows for a single voice too).
            model.toggle(ids[1])
        case "voices-import":
            // A real round trip through the importer: two voices exported and imported back, and a file that isn't one.
            let archive = folder.appendingPathComponent("Radio Drama Cast.encorevoice")
            try? await deps.voices.export(Array(ids.suffix(2)), to: archive)
            let junk = folder.appendingPathComponent("holiday-photos.encorevoice")
            try? Data("not a voice file".utf8).write(to: junk)
            await model.importFiles([archive, junk])
            // The voices are clones, so the consent sheet asked first; this state shows the result once confirmed.
            model.pendingImport?.consent = true
            await model.confirmImport()
        default:
            break
        }
    }

    // MARK: Design

    private static func design(_ state: String, deps: AppDependencies, folder: URL) async {
        let model = deps.screenModel("Design") { DesignModel(deps: deps) }
        await model.prepare()
        if state == "design-noModel" || state == "design-empty" { return }
        await seedVoices(deps, folder: folder, count: 2)
        model.description = DesignModel.examples[0].text
        func candidate(_ i: Int, pitch: Double, seconds: Double) -> VoiceDesignCandidate {
            let url = folder.appendingPathComponent("candidate-\(i).wav")
            try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: seconds, seed: 30 + i, pitch: pitch), to: url)
            return VoiceDesignCandidate(audioPath: url.path, transcript: model.sampleText, description: model.description,
                                        modelID: "qwen3-tts-voicedesign", duration: seconds, seed: 4100 + i)
        }
        let round1 = [candidate(0, pitch: 96, seconds: 6.4), candidate(1, pitch: 118, seconds: 5.9), candidate(2, pitch: 88, seconds: 7.1)]
        let identity = JobRunner.Identity(kind: .voiceDesign, modelID: "qwen3-tts-voicedesign", modelName: "Qwen3-TTS VoiceDesign")
        switch state {
        case "design-running":
            model.debugSet(auditions: [.init(candidate: round1[0], round: 1, number: 1)], round: 1, roundSize: 3)
            model.runner.debugShow(.running, identity: identity, stage: "Designing voice 2 of 3", progress: 0.41,
                                   startedAt: Date().addingTimeInterval(-7))
        case "design-saving":
            let a = round1.enumerated().map { DesignModel.Audition(candidate: $1, round: 1, number: $0 + 1) }
            model.debugSet(auditions: a, round: 1, keeping: a[1].id)
            model.keepName = "Captain Gale"
            model.keepTags = ["gravel", "sea"]
        case "design-kept":
            var a = round1.enumerated().map { DesignModel.Audition(candidate: $1, round: 1, number: $0 + 1) }
            let v = Voice(name: "Captain Gale", tags: ["gravel", "sea"], origin: .designed, transcript: model.sampleText,
                          designPrompt: model.description, sourceModelID: "qwen3-tts-voicedesign", duration: 5.9)
            let ref = folder.appendingPathComponent("gale.wav")
            try? FileManager.default.copyItem(atPath: round1[1].audioPath, toPath: ref.path)
            if let saved = try? await deps.voices.add(v, referenceAudio: ref, move: true) {
                a[1].savedVoice = saved
                model.debugSet(auditions: a, round: 1, tryoutFor: a[1].id)
                let take = folder.appendingPathComponent("gale-first.wav")
                try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: 5.2, seed: 44, pitch: 112), to: take)
                let record = GenerationRecord(kind: .speech, title: "Captain Gale — first words", text: "Hello…", modelID: "qwen3-tts-base",
                                              modelName: "Qwen3-TTS Base", voiceName: "Captain Gale", voiceID: saved.id,
                                              audioPath: take.path, duration: 5.2, sampleRate: 24_000, elapsed: 2.9)
                model.tryout.debugShow(voice: saved, choice: ModelChoice(modelID: "qwen3-tts-base", variantID: "1.7b-8bit"), result: record)
            }
        default: // design-ready: two rounds
            let round2 = [candidate(3, pitch: 102, seconds: 6.0), candidate(4, pitch: 92, seconds: 6.6), candidate(5, pitch: 110, seconds: 5.7)]
            let a = round2.enumerated().map { DesignModel.Audition(candidate: $1, round: 2, number: $0 + 1) }
                + round1.enumerated().map { DesignModel.Audition(candidate: $1, round: 1, number: $0 + 1) }
            model.debugSet(auditions: a, round: 2)
            model.runner.debugShow(.idle, identity: nil, lastOutcome: .finished(elapsed: 11.2))
        }
    }

    // MARK: Inspector alone

    /// The inspector drawn on its own at full height so its facts rows show (`--snapshot-only Voices-Inspector,…`):
    /// at the real panel width (340) and squeezed (290) with a long model name and last year's date.
    static var inspectorFixtures: [FeatureFixture] {
        [("Voices-Inspector", 340.0, false), ("Voices-Inspector-Narrow", 290.0, true)].map { name, width, old in
            FeatureFixture(name: name, section: .voices, size: CGSize(width: width + 2 * Theme.Space.m, height: 1240),
                           prepare: { _ in .init() },
                           sheet: { deps, _ in
                               AnyView(Group {
                                   if let v = deps.voices.voices.first(where: { $0.sourceModelID == (old ? "chatterbox-multilingual" : "qwen3-tts-base") }) {
                                       VoiceInspector(voice: v, reference: deps.voices.referenceAudioURL(for: v.id), onClose: {}, onCast: {},
                                                      onDuplicate: {}, onExport: {}, onDelete: {})
                                           .frame(width: width)
                                           .padding(Theme.Space.m)
                                   }
                               })
                           },
                           seed: { deps in
                               let folder = FileManager.default.temporaryDirectory
                                   .appendingPathComponent("EncoreSnapshot-inspector-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6))")
                               try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                               let url = folder.appendingPathComponent("ref.wav")
                               try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: 9.4, seed: 3, pitch: 108), to: url)
                               // 22:40 on a fixed day, so the 12/24-hour setting shows.
                               var c = DateComponents(); c.year = old ? 2025 : Calendar.current.component(.year, from: Date())
                               c.month = 11; c.day = 20; c.hour = 22; c.minute = 40
                               let when = Calendar.current.date(from: c) ?? Date()
                               let v = Voice(name: "Captain Reyes", tags: ["narration", "warm"], origin: .cloned,
                                             transcript: "Steady as she goes. We'll make port by morning if this wind holds.",
                                             language: "en", sourceModelID: old ? "chatterbox-multilingual" : "qwen3-tts-base", duration: 9.4,
                                             createdAt: when, consentConfirmedAt: when)
                               _ = try? await deps.voices.add(v, referenceAudio: url, move: true)
                           })
        } + importConsentFixtures
    }

    // MARK: Import consent sheet

    /// The import consent sheet on its own (`--snapshot-only Voices-ImportConsent,…`): a file with two cloned voices
    /// and a designed one plus a file that isn't a voice file, before and after the tick; and a single cloned voice.
    static var importConsentFixtures: [FeatureFixture] {
        [("Voices-ImportConsent", false, false), ("Voices-ImportConsent-Ticked", true, false), ("Voices-ImportConsent-One", false, true)]
            .map { name, ticked, one in
                FeatureFixture(name: name, section: .voices, size: CGSize(width: 480, height: one ? 470 : 600),
                               prepare: { _ in .init() },
                               sheet: { deps, _ in AnyView(ImportConsentSheet(model: deps.screenModel("Voices") { VoicesModel(deps: deps) })) },
                               seed: { deps in
                                   let folder = FileManager.default.temporaryDirectory
                                       .appendingPathComponent("EncoreSnapshot-import-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6))")
                                   try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                   // The file is made by a separate "sender" library in the temporary folder.
                                   let sender = VoiceLibrary(directory: folder.appendingPathComponent("Sender"), deletesToTrash: false)
                                   let cast = [
                                       Voice(name: "Captain Reyes", origin: .cloned, transcript: "Steady as she goes.", language: "en", duration: 9.4,
                                             consentConfirmedAt: Date().addingTimeInterval(-40 * 86_400)),
                                       Voice(name: "Hélène", origin: .cloned, transcript: "Il était une fois…", language: "fr", duration: 12.8,
                                             consentConfirmedAt: Date().addingTimeInterval(-60 * 86_400)),
                                       Voice(name: "Night Desk", origin: .designed, transcript: "You're listening to the night desk.", language: "en",
                                             designPrompt: "A calm, low-voiced late-night radio host.", duration: 7.3),
                                   ]
                                   var ids: [UUID] = []
                                   for (i, v) in cast.prefix(one ? 1 : 3).enumerated() {
                                       let clip = folder.appendingPathComponent("send-\(i).wav")
                                       try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: v.duration, seed: 50 + i, pitch: [108, 190, 120][i]), to: clip)
                                       if let saved = try? await sender.add(v, referenceAudio: clip, move: true) { ids.append(saved.id) }
                                   }
                                   let archive = folder.appendingPathComponent(one ? "Captain Reyes.encorevoice" : "Radio Drama Cast.encorevoice")
                                   try? await sender.export(ids, to: archive)
                                   var files = [archive]
                                   if !one {
                                       let junk = folder.appendingPathComponent("holiday-photos.encorevoice")
                                       try? Data("not a voice file".utf8).write(to: junk)
                                       files.append(junk)
                                   }
                                   let model = deps.screenModel("Voices") { VoicesModel(deps: deps) }
                                   await model.importFiles(files)
                                   if ticked { model.pendingImport?.consent = true }
                               })
            }
    }

    // MARK: Seeding

    @discardableResult
    private static func seedVoices(_ deps: AppDependencies, folder: URL, count: Int) async -> [UUID] {
        let day: TimeInterval = 86_400
        let all: [Voice] = [
            Voice(name: "Captain Reyes", tags: ["narration", "warm", "low"], origin: .cloned, transcript: "Steady as she goes. We'll make port by morning if this wind holds.",
                  language: "en", notes: "From the 2019 harbor documentary.", sourceModelID: "qwen3-tts-base", duration: 9.4,
                  createdAt: Date().addingTimeInterval(-1 * day), consentConfirmedAt: Date().addingTimeInterval(-1 * day)),
            Voice(name: "Mira", tags: ["bright", "young"], origin: .designed, transcript: "Hello there. It's lovely to finally meet you.",
                  language: "en", designPrompt: "A bright, quick-witted young woman, amused and a little breathless.",
                  sourceModelID: "qwen3-tts-voicedesign", duration: 6.1, createdAt: Date().addingTimeInterval(-2 * day)),
            Voice(name: "Old Tom", tags: ["gravel", "character"], origin: .imported, transcript: "Back in my day we walked to school, uphill, both ways.",
                  language: "en", duration: 11.2, createdAt: Date().addingTimeInterval(-5 * day)),
            Voice(name: "Hélène", tags: ["narration", "french"], origin: .cloned, transcript: "Il était une fois, dans un petit village au bord de la mer…",
                  language: "fr", sourceModelID: "chatterbox-turbo", duration: 12.8, createdAt: Date().addingTimeInterval(-9 * day),
                  consentConfirmedAt: Date().addingTimeInterval(-9 * day)),
            Voice(name: "Night Desk", tags: ["radio", "calm", "narration"], origin: .designed, transcript: "You're listening to the night desk.",
                  language: "en", designPrompt: "A calm, low-voiced late-night radio host, smooth and unhurried.",
                  sourceModelID: "voxcpm2", duration: 7.3, createdAt: Date().addingTimeInterval(-12 * day)),
            Voice(name: "Dad (voice memo)", tags: ["family"], origin: .cloned, transcript: "Call me when you land, okay? Love you.",
                  language: "en", duration: 5.6, createdAt: Date().addingTimeInterval(-20 * day), consentConfirmedAt: Date().addingTimeInterval(-20 * day)),
            Voice(name: "Kenji", tags: ["japanese", "narration"], origin: .cloned, transcript: "今日はいい天気ですね。散歩に行きましょう。",
                  language: "ja", duration: 8.0, createdAt: Date().addingTimeInterval(-31 * day), consentConfirmedAt: Date().addingTimeInterval(-31 * day)),
        ]
        var ids: [UUID] = []
        for (i, v) in all.prefix(count).enumerated() {
            let url = folder.appendingPathComponent("seed-\(i).wav")
            try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: v.duration, seed: i + 1, pitch: [108, 214, 92, 190, 120, 100, 140][i]), to: url)
            if let saved = try? await deps.voices.add(v, referenceAudio: url, move: true) { ids.append(saved.id) }
        }
        return ids
    }

    /// Models "on disk": a snapshot folder with a config per repo is enough for the service to accept them.
    private static func markDownloaded(_ ids: [String], deps: AppDependencies) {
        let layout = deps.service.hub.layout
        let commit = String(repeating: "f1", count: 20)
        let fm = FileManager.default
        for id in ids {
            guard let m = deps.catalog.model(id) else { continue }
            for repo in m.defaultVariant.allRepos {
                let ref = layout.refFile(repo, ref: "main")
                let snap = layout.snapshotDirectory(repo, commit: commit)
                try? fm.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.createDirectory(at: snap, withIntermediateDirectories: true)
                try? Data(commit.utf8).write(to: ref)
                try? Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
            }
        }
    }
}
#endif
