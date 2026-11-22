import Foundation
import Testing
@testable import EncoreCore

@MainActor @Suite struct ServicePipelineTests {
    nonisolated static let speaker = testManifest("speaker", capabilities: ["presetVoices": true, "cloning": true, "cloningUsesTranscript": true],
                                      presets: ["af_heart", "am_adam"], maxChunk: 80,
                                      reference: ["minSeconds": 3, "maxSeconds": 10, "transcript": "recommended"],
                                      parameters: [["key": "temperature", "label": "T", "type": "float", "tier": "basic", "default": 0.8]])

    func world(_ models: [ModelManifest] = [speaker], backend: FakeBackend? = nil) throws -> (ServiceWorld, FakeBackend) {
        let b = backend ?? FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .cloning]])
        return (try ServiceWorld(models: models, backends: [b]), b)
    }

    func noPost() -> PostProcessingOptions { var p = PostProcessingOptions(); p.normalizeLoudness = false; return p }

    @Test func assembledDurationIsChunksPlusGapsPlusPauses() async throws {
        let (w, b) = try world()
        var r = SpeechRequest(modelID: "speaker", text: """
            The first paragraph is long enough that it has to be split into more than one chunk. It keeps going for a while.

            A second paragraph. [pause 1.2s] After the pause, the last words.
            """)
        r.voice = .preset("af_heart")
        r.post = noPost()
        let events = try await collect(w.service.speak(r))
        let record = try #require(finishedRecord(events))

        let plan = ScriptPlanner(request: r, manifest: Self.speaker, library: [], pronunciations: []).plan(r.text)
        #expect(plan.chunks.count >= 4)
        let speech = plan.chunks.reduce(0.0) { $0 + FakeBackend.seconds(for: $1.text) }
        let gaps = plan.chunks.reduce(0.0) { $0 + $1.gapAfter }
        let pauses = plan.items.reduce(0.0) { if case .pause(let s, _) = $1 { $0 + s } else { $0 } }
        #expect(pauses == 1.2)
        #expect(abs(record.duration - (speech + gaps + pauses)) < 0.001 * Double(plan.items.count))
        #expect(b.synthCalls.map(\.text) == plan.chunks.map(\.text))

        let file = try await AudioReader.read(record.audioURL)
        #expect(abs(file.duration - record.duration) < 0.001)
        #expect(file.sampleRate == 24_000)
    }

    @Test func voiceSwitchTagsReachTheEngineWithTheRightVoices() async throws {
        let (w, b) = try world()
        let ava = try await w.addVoice("Ava")
        var r = SpeechRequest(modelID: "speaker", text: "Hello there. [voice: Ava] I am Ava now. [voice: am_adam] And Adam. [voice: default] Back.")
        r.voice = .preset("af_heart")
        r.post = noPost()
        let record = try #require(finishedRecord(try await collect(w.service.speak(r))))
        let calls = b.synthCalls
        #expect(calls.map(\.text) == ["Hello there.", "I am Ava now.", "And Adam.", "Back."])
        #expect(calls[0].voice == EngineVoice(preset: "af_heart"))
        #expect(calls[1].voice?.referenceAudio == w.voices.referenceAudioURL(for: ava.id))
        #expect(calls[1].voice?.referenceText == "This is my reference voice.")
        #expect(calls[2].voice == EngineVoice(preset: "am_adam"))
        #expect(calls[3].voice == EngineVoice(preset: "af_heart"))
        #expect(record.voiceName == "Af_Heart")
    }

    @Test func unknownVoiceTagIsATypedError() async throws {
        let (w, _) = try world()
        await #expect(throws: ServiceError.unknownVoiceTags(["Nobody"])) {
            _ = try await collect(w.service.speak(SpeechRequest(modelID: "speaker", text: "Hi. [voice: Nobody] Hello.")))
        }
        await #expect(throws: ServiceError.emptyScript) {
            _ = try await collect(w.service.speak(SpeechRequest(modelID: "speaker", text: "  [pause 1s] ")))
        }
    }

    @Test func pronunciationsAreApplied() async throws {
        let (w, b) = try world()
        try w.pronunciations.save(PronunciationEntry(term: "Nguyen", replacement: "win"))
        var r = SpeechRequest(modelID: "speaker", text: "Ask Nguyen about it.")
        r.post = noPost()
        _ = try await collect(w.service.speak(r))
        #expect(b.synthCalls.map(\.text) == ["Ask win about it."])
        r.applyPronunciations = false
        _ = try await collect(w.service.speak(r))
        #expect(b.synthCalls.last?.text == "Ask Nguyen about it.")
    }

    @Test func postProcessingIsApplied() async throws {
        let (w, _) = try world()
        var r = SpeechRequest(modelID: "speaker", text: "One sentence here. [pause 4s] Another sentence there.")
        r.post = noPost()
        let plain = try #require(finishedRecord(try await collect(w.service.speak(r))))
        r.post.normalizeLoudness = true
        r.post.targetLUFS = -23
        r.post.removeSilence = true
        r.post.maxSilenceSeconds = 0.5
        let processed = try #require(finishedRecord(try await collect(w.service.speak(r))))
        #expect(processed.duration < plain.duration - 3)
        let lufs = Loudness.integratedLoudness(try await AudioReader.read(processed.audioURL))
        #expect(abs(lufs - -23) < 1)
    }

    @Test func historyRecordCarriesTheMetadata() async throws {
        let (w, _) = try world()
        let ava = try await w.addVoice("Ava")
        var r = SpeechRequest(modelID: "speaker", text: "Testing the record.")
        r.voice = .library(ava.id)
        r.parameters = ["seed": .int(7)]
        r.title = "My take"
        let record = try #require(finishedRecord(try await collect(w.service.speak(r))))
        let stored = try #require(try await w.history.item(record.id)?.generation)
        #expect(stored == record)
        #expect(stored.kind == .speech && stored.title == "My take" && stored.text == r.text)
        #expect(stored.modelID == "speaker" && stored.modelName == "Speaker")
        #expect(stored.voiceName == "Ava" && stored.voiceID == ava.id)
        #expect(stored.parameters == ["temperature": .double(0.8), "seed": .int(7)])
        #expect(stored.sampleRate == 24_000)
        #expect(FileManager.default.fileExists(atPath: stored.audioPath))
        #expect(stored.audioURL.deletingLastPathComponent().standardizedFileURL == w.history.audioDirectory.standardizedFileURL)
        #expect(w.settings.lastUsedModels[.cloning] == "speaker")
        // Everything Studio needs to restore the take.
        #expect(stored.variantID == w.catalog.model("speaker")?.defaultVariant.id)
        #expect(stored.post == r.post)
        #expect(stored.language == nil && stored.instruct == nil)
        #expect(stored.runtime != nil)
    }

    @Test func recordsWrittenBeforeTheNewFieldsStillDecode() throws {
        let old = """
        {"id":"7B4C1F3E-2A4B-4C5D-9E6F-1A2B3C4D5E6F","kind":"speech","title":"Old","text":"Hello","modelID":"soprano",
         "modelName":"Soprano","parameters":{},"audioPath":"/tmp/x.wav","duration":1.5,"sampleRate":24000,
         "createdAt":700000000,"elapsed":0.4,"favorite":true}
        """
        let r = try JSONDecoder().decode(GenerationRecord.self, from: Data(old.utf8))
        #expect(r.title == "Old" && r.favorite && r.variantID == nil && r.post == nil && r.runtime == nil)
        let oldT = """
        {"id":"7B4C1F3E-2A4B-4C5D-9E6F-1A2B3C4D5E60","sourceName":"a.wav","sourcePath":"/tmp/a.wav","modelID":"whisper",
         "modelName":"Whisper","transcript":{"text":"hi","segments":[]},"createdAt":700000000,"elapsed":1}
        """
        let t = try JSONDecoder().decode(TranscriptionRecord.self, from: Data(oldT.utf8))
        #expect(t.sourceName == "a.wav" && t.language == nil && t.timestamps == nil)
    }

    @Test func cancelingMidRunLeavesNothingBehind() async throws {
        let (w, b) = try world()
        b.delay = .milliseconds(150)
        var r = SpeechRequest(modelID: "speaker", text: (1...8).map { "Sentence number \($0) is here and long enough." }.joined(separator: "\n\n"))
        r.post = noPost()
        let stream = w.service.speak(r)
        let consumer = Task.detached {
            for try await e in stream { if case .stage(let s) = e, s.hasPrefix("Generating 2") { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        try await consumer.value  // the consuming task canceled itself: the stream ends and the request stops
        let canceledAt = Date()
        await w.service.runtime.waitUntilIdle()
        #expect(Date().timeIntervalSince(canceledAt) < 1)
        #expect(b.synthCalls.count <= 3)
        #expect(try await w.history.count() == 0)
        #expect(w.leftovers().isEmpty, "\(w.leftovers())")
    }

    @Test func cancelingTheConsumingTaskStopsPromptly() async throws {
        let (w, b) = try world()
        b.delay = .seconds(5)
        var r = SpeechRequest(modelID: "speaker", text: "Only one long chunk to generate.")
        r.post = noPost()
        let stream = w.service.speak(r)
        let consumer = Task.detached { try await collect(stream) }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        let t = Date()
        let events = try await consumer.value  // a canceled stream just ends, without a record
        #expect(finishedRecord(events) == nil)
        await w.service.runtime.waitUntilIdle()
        #expect(Date().timeIntervalSince(t) < 1)
        #expect(try await w.history.count() == 0)
        #expect(w.leftovers().isEmpty)
    }

    @Test func libraryVoiceOnModelWithoutCloningIsATypedError() async throws {
        let plain = testManifest("plain", capabilities: ["presetVoices": true], presets: ["one"])
        let (w, _) = try world([plain], backend: FakeBackend(.mlxSwift, features: ["plain": .synthesis]))
        let ava = try await w.addVoice("Ava")
        var r = SpeechRequest(modelID: "plain", text: "Hello.")
        r.voice = .library(ava.id)
        let error = await #expect(throws: ServiceError.self) { _ = try await collect(w.service.speak(r)) }
        if case .featureUnsupported("plain", _, .cloning, _)? = error {} else { Issue.record("\(String(describing: error))") }
        r.voice = .preset("nope")
        await #expect(throws: ServiceError.unknownPresetVoice(name: "nope", modelID: "plain")) { _ = try await collect(w.service.speak(r)) }
        r.voice = .library(UUID())
        await #expect(throws: ServiceError.self) { _ = try await collect(w.service.speak(r)) }
    }

    @Test func modelNotDownloadedCarriesModelAndVariant() async throws {
        let w = try ServiceWorld(models: [Self.speaker], backends: [FakeBackend(.mlxSwift, features: ["speaker": .synthesis])],
                                 downloaded: [])
        await #expect(throws: ServiceError.modelNotDownloaded(modelID: "speaker", variantID: "v1", modelName: "Speaker",
                                                              variantLabel: "V1", partial: false)) {
            _ = try await collect(w.service.speak(SpeechRequest(modelID: "speaker", text: "Hi.")))
        }
        await #expect(throws: ServiceError.unknownModel("nope")) {
            _ = try await collect(w.service.speak(SpeechRequest(modelID: "nope", text: "Hi.")))
        }
    }

    @Test func longReferenceIsTrimmedAndReTranscribed() async throws {
        let stt = testManifest("whisper-large-v3-turbo", engine: "whisper", tasks: ["stt"])
        let b = FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .cloning], "whisper": .transcription])
        let (w, _) = try world([Self.speaker, stt], backend: b)
        // 25 s of speech-like audio with a pause every 4 s.
        var samples: [Float] = []
        for _ in 0..<5 { samples += Signal.speechLike(seconds: 4, rate: 24_000) + Signal.silence(1, rate: 24_000) }
        let clip = try w.wav("long.wav", samples)
        let voice = try await w.voices.add(Voice(name: "Long", origin: .cloned, transcript: "Twenty five seconds of words.", duration: 25),
                                           referenceAudio: clip)
        var r = SpeechRequest(modelID: "speaker", text: "Say it in the long voice.")
        r.voice = .library(voice.id)
        r.post = noPost()
        _ = try await collect(w.service.speak(r))
        let sent = try #require(b.synthCalls.first?.voice)
        #expect(sent.referenceText == "Fake transcript.")
        #expect(b.transcribeCalls.count == 1)
        #expect(w.leftovers(includeHistory: false).isEmpty)  // the trimmed clip was a temp file
        #expect(Set(b.loads) == ["speaker", "whisper-large-v3-turbo"])
    }

    @Test func trimmedReferenceEndsInAPauseUnderTheLimit() async throws {
        let (w, _) = try world()
        var samples: [Float] = []
        for _ in 0..<5 { samples += Signal.speechLike(seconds: 4, rate: 24_000) + Signal.silence(1, rate: 24_000) }
        let clip = try w.wav("long.wav", samples)
        let temp = TempFiles(in: w.scratch)
        defer { temp.cleanup() }
        let out = try await w.service.trimReference(clip, spec: ReferenceSpec(minSeconds: 3, maxSeconds: 10, transcript: .recommended), temp: temp)
        let d = try await AudioReader.read(out).duration
        #expect(d <= 10 && d > 8)  // cut in the pause after the second sentence (8–9 s)
    }
}
