import Foundation
import Testing
@testable import EncoreCore

/// Conversations, voice design, and voice conversion through the service.
@MainActor @Suite struct ServiceFeatureTests {
    nonisolated static let speaker = testManifest("speaker", capabilities: ["presetVoices": true, "cloning": true, "cloningUsesTranscript": true],
                                      presets: ["p1", "p2"], reference: ["minSeconds": 3, "maxSeconds": 15, "transcript": "recommended"])
    nonisolated static let designer = testManifest("designer", engine: "speaker", capabilities: ["voiceDesign": true],
                                       parameters: [["key": "seed", "label": "Seed", "type": "seed", "tier": "advanced"]])
    nonisolated static let changer = testManifest("changer", tasks: ["voiceConversion"], sampleRate: 24_000,
                                      reference: ["minSeconds": 3, "maxSeconds": 10, "transcript": "unused"])

    func noPost() -> PostProcessingOptions { var p = PostProcessingOptions(); p.normalizeLoudness = false; return p }

    func conversation() -> (ConversationScript, ConversationScript.Speaker, ConversationScript.Speaker) {
        var script = ConversationScript()
        script.title = "Two voices"
        var a = ConversationScript.Speaker(name: "Ann"); a.voice = .preset("p1")
        var b = ConversationScript.Speaker(name: "Ben"); b.voice = .preset("p2")
        script.speakers = [a, b]
        var l2 = ConversationScript.Line(speakerID: b.id, text: "Hi Ann, how are you?")
        l2.pauseAfter = 1.0
        script.lines = [ConversationScript.Line(speakerID: a.id, text: "Hello Ben."), l2,
                        ConversationScript.Line(speakerID: a.id, text: "Fine. [pause 0.5s] Thanks.")]
        return (script, a, b)
    }

    @Test func conversationVoicesAndPauses() async throws {
        let backend = FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .cloning]])
        let w = try ServiceWorld(models: [Self.speaker], backends: [backend])
        let (script, _, _) = conversation()
        var r = ConversationRequest(modelID: "speaker", script: script)
        r.pauseSeconds = 0.4
        r.post = noPost()
        let record = try #require(finishedRecord(try await collect(w.service.renderConversation(r))))
        #expect(backend.synthCalls.map(\.text) == ["Hello Ben.", "Hi Ann, how are you?", "Fine.", "Thanks."])
        #expect(backend.synthCalls.map { $0.voice?.preset } == ["p1", "p2", "p1", "p1"])
        let speech = backend.synthCalls.reduce(0.0) { $0 + FakeBackend.seconds(for: $1.text) }
        // Pause after line 1 (0.4, default), after line 2 (1.0, its own), the tag inside line 3 (0.5); none after the last.
        #expect(abs(record.duration - (speech + 0.4 + 1.0 + 0.5)) < 0.002)
        #expect(record.kind == .conversation && record.voiceName == "Ann, Ben" && record.title == "Two voices")
        #expect(record.text.contains("Ben: Hi Ann, how are you?"))
    }

    @Test func unsavedRendersLeaveHistoryAlone() async throws {
        let backend = FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .cloning]])
        let w = try ServiceWorld(models: [Self.speaker], backends: [backend])
        var r = ConversationRequest(modelID: "speaker", script: conversation().0)
        r.post = noPost()
        r.saveToHistory = false
        let record = try #require(finishedRecord(try await collect(w.service.renderConversation(r))))
        var s = SpeechRequest(modelID: "speaker", text: "Just a try-out.")
        s.voice = .preset("p1")
        s.saveToHistory = false
        let take = try #require(finishedRecord(try await collect(w.service.speak(s))))
        #expect(try await w.history.count() == 0)
        for url in [record.audioURL, take.audioURL] {
            #expect(url.deletingLastPathComponent().standardizedFileURL == w.service.unsavedDirectory.standardizedFileURL)
            #expect(try await AudioReader.read(url).duration > 0)
        }
        // Older JSON without the field still saves.
        let decoded = try JSONDecoder().decode(SpeechRequest.self, from: Data(#"{"modelID":"speaker","text":"Hi."}"#.utf8))
        #expect(decoded.saveToHistory)
    }

    @Test func reRenderingOnlyRegeneratesChangedLines() async throws {
        let backend = FakeBackend(.mlxSwift, features: ["speaker": .synthesis])
        let w = try ServiceWorld(models: [Self.speaker], backends: [backend])
        var (script, _, _) = conversation()
        var r = ConversationRequest(modelID: "speaker", script: script)
        r.post = noPost()
        _ = try await collect(w.service.renderConversation(r))
        #expect(backend.synthCalls.count == 4)
        script.lines[1].text = "Hi Ann! How have you been?"
        r.script = script
        _ = try await collect(w.service.renderConversation(r))
        #expect(backend.synthCalls.count == 5)
        #expect(backend.synthCalls.last?.text == "Hi Ann! How have you been?")
        // Changing a voice invalidates that speaker's lines.
        r.script.speakers[0].voice = .preset("p2")
        _ = try await collect(w.service.renderConversation(r))
        #expect(backend.synthCalls.count == 8)
        r.reuseRenderedLines = false
        _ = try await collect(w.service.renderConversation(r))
        #expect(backend.synthCalls.count == 12)
    }

    @Test func designCandidatesThenSaveThenSpeakWithTheVoice() async throws {
        let backend = FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .cloning, .voiceDesign]])
        let w = try ServiceWorld(models: [Self.speaker, Self.designer], backends: [backend])
        var r = VoiceDesignRequest(modelID: "designer", description: "A warm, raspy older man.", sampleText: "The quick brown fox jumps over the lazy dog.")
        r.candidates = 3
        r.parameters = ["seed": .int(40)]
        let events = try await collect(w.service.designVoice(r))
        let candidates = events.compactMap { if case .candidate(let c) = $0 { c } else { nil } }
        #expect(candidates.count == 3)
        guard case .finished? = events.last else { Issue.record("not finished"); return }
        #expect(backend.synthCalls.allSatisfy { $0.instruct == "A warm, raspy older man." && $0.voice == nil })
        #expect(backend.synthCalls.map { $0.parameters["seed"] } == [.int(40), .int(41), .int(42)])
        #expect(candidates.map(\.seed) == [40, 41, 42])
        #expect(Set(candidates.map(\.audioPath)).count == 3)
        for c in candidates { #expect(FileManager.default.fileExists(atPath: c.audioPath)) }
        #expect(try await w.history.count() == 0)

        let voice = try await w.service.saveDesignedVoice(candidates[1], name: "Old Sailor", tags: ["designed"])
        #expect(voice.origin == .designed && voice.designPrompt == "A warm, raspy older man.")
        #expect(voice.transcript == "The quick brown fox jumps over the lazy dog." && voice.sourceModelID == "designer")
        w.service.discardDesignCandidates(candidates)
        #expect(candidates.allSatisfy { !FileManager.default.fileExists(atPath: $0.audioPath) })

        var speak = SpeechRequest(modelID: "speaker", text: "Now I speak with the designed voice.")
        speak.voice = .library(voice.id)
        speak.post = noPost()
        let record = try #require(finishedRecord(try await collect(w.service.speak(speak))))
        let sent = try #require(backend.synthCalls.last?.voice)
        #expect(sent.referenceAudio == w.voices.referenceAudioURL(for: voice.id))
        #expect(sent.referenceText == "The quick brown fox jumps over the lazy dog.")
        #expect(record.voiceName == "Old Sailor")
    }

    @Test func voiceTryoutsStayOutOfHistory() async throws {
        let backend = FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .cloning, .voiceDesign]])
        let w = try ServiceWorld(models: [Self.speaker, Self.designer], backends: [backend])
        // Keeping a designed voice adds one History record: the kept audition, with its own copy of the clip.
        var d = VoiceDesignRequest(modelID: "designer", description: "Bright.", sampleText: "Hello there, nice to meet you.")
        d.candidates = 1
        let events = try await collect(w.service.designVoice(d))
        let candidate = try #require(events.compactMap { if case .candidate(let c) = $0 { c } else { nil } }.first)
        let designed = try await w.service.saveDesignedVoice(candidate, name: "Bright One")
        w.service.discardDesignCandidates([candidate])
        #expect(try await w.history.count() == 1)
        #expect(try await w.history.count(HistoryQuery(kinds: [.voiceDesign])) == 1)
        let cloned = try await w.addVoice("Ann")

        // "Hear it" try-outs of either voice add nothing; their takes are scratch files the caller deletes.
        for voice in [designed, cloned] {
            let request = SpeechRequest.voiceTryout(voice, modelID: "speaker", variantID: nil,
                                                    text: "Hello, I'm \(voice.name).", language: nil)
            #expect(!request.saveToHistory && request.voice == .library(voice.id))
            let take = try #require(finishedRecord(try await collect(w.service.speak(request))))
            #expect(take.voiceID == voice.id)
            #expect(take.audioURL.deletingLastPathComponent().standardizedFileURL == w.service.unsavedDirectory.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: take.audioURL.path))
        }
        #expect(try await w.history.count() == 1)
        #expect(try await w.history.count(HistoryQuery(kinds: [.speech])) == 0)
    }

    @Test func designOnAModelWithoutDesignIsATypedError() async throws {
        let w = try ServiceWorld(models: [Self.speaker], backends: [FakeBackend(.mlxSwift, features: ["speaker": .synthesis])])
        let error = await #expect(throws: ServiceError.self) {
            _ = try await collect(w.service.designVoice(VoiceDesignRequest(modelID: "speaker", description: "x", sampleText: "y")))
        }
        guard case .featureUnsupported("speaker", _, .voiceDesign, _)? = error else { Issue.record("\(String(describing: error))"); return }
    }

    @Test func canceledDesignDeletesItsCandidates() async throws {
        let backend = FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .voiceDesign]])
        let w = try ServiceWorld(models: [Self.designer], backends: [backend])
        backend.delay = .milliseconds(300)
        var r = VoiceDesignRequest(modelID: "designer", description: "Bright.", sampleText: "Hello there.")
        r.candidates = 4
        let stream = w.service.designVoice(r)
        let consumer = Task.detached { try await collect(stream) }
        // Cancel from the engine's side the moment the second candidate starts (the first is on disk by then),
        // so the test doesn't depend on how busy the main actor is.
        backend.onSynthesize = { n in if n == 2 { consumer.cancel() } }
        let events = try await consumer.value
        await w.service.runtime.waitUntilIdle()
        #expect(backend.synthCalls.count == 2)
        #expect(events.allSatisfy { if case .finished = $0 { false } else { true } })
        #expect(w.leftovers().isEmpty)  // the finished first candidate was deleted too
    }

    @Test func conversionStitchingPreservesDuration() async throws {
        let backend = FakeBackend(.python, features: ["changer": .voiceConversion])
        let w = try ServiceWorld(models: [Self.changer], backends: [backend])
        // 47 s of speech with a pause every ~6 s, at 16 kHz.
        var samples: [Float] = []
        for i in 0..<8 { samples += Signal.speechLike(seconds: 5 + Double(i % 3) * 0.3, rate: 16_000) + Signal.silence(0.7, rate: 16_000) }
        let source = try w.wav("monologue.wav", samples, rate: 16_000)
        let sourceDuration = Double(samples.count) / 16_000
        let target = try await w.addVoice("Target", seconds: 12)
        var r = VoiceConversionRequest(modelID: "changer", sourcePath: source.path, voice: .library(target.id))
        r.post = noPost()
        let events = try await collect(w.service.convertVoice(r))
        let record = try #require(finishedRecord(events))
        #expect(backend.convertCalls.count >= 3)  // cut into ≤ 20 s pieces
        #expect(abs(record.duration - sourceDuration) < 0.01)
        #expect(record.kind == .voiceChange && record.text == "monologue.wav" && record.voiceName == "Target")
        // The 12 s reference was trimmed to the model's 10 s; no transcript is needed for this model.
        let ref = try #require(backend.convertCalls.first?.target.referenceAudio)
        #expect(ref != w.voices.referenceAudioURL(for: target.id))
        #expect(w.leftovers(includeHistory: false).isEmpty)

        r.voice = .automatic
        let error = await #expect(throws: ServiceError.self) { _ = try await collect(w.service.convertVoice(r)) }
        guard case .invalidRequest? = error else { Issue.record("\(String(describing: error))"); return }
    }

    @Test func aModelWithoutAutomaticLanguageGetsTheScriptsOrTheVoices() async throws {
        var multi = testManifest("multi", capabilities: ["cloning": true, "needsLanguage": true])
        multi.languages = ["en", "es", "fr"].map { ModelLanguage(code: $0, name: $0) }
        var auto = testManifest("auto", capabilities: ["cloning": true])
        auto.languages = multi.languages
        let backend = FakeBackend(.mlxSwift, features: ["multi": [.synthesis, .cloning], "auto": [.synthesis, .cloning]])
        let w = try ServiceWorld(models: [multi, auto], backends: [backend])
        var voice = try await w.addVoice("Ines")
        voice.language = "fr"
        try w.voices.update(voice)
        func speak(_ model: String, _ text: String, language: String? = nil) async throws -> String? {
            var r = SpeechRequest(modelID: model, text: text)
            r.voice = .library(voice.id)
            r.language = language
            r.post = noPost()
            _ = try await collect(w.service.speak(r))
            return backend.synthCalls.last?.language
        }

        // Automatic: the script's language, else the voice's (instead of the model's English default).
        #expect(try await speak("multi", "Buenos días, ¿cómo estás? Hoy hace un tiempo estupendo en la ciudad.") == "es")
        #expect(try await speak("multi", "Ok.") == "fr")
        // A language that was chosen is used as is, and a model with its own automatic gets nil.
        #expect(try await speak("multi", "Buenos días, ¿cómo estás? Hoy hace un tiempo estupendo.", language: "en") == "en")
        #expect(try await speak("auto", "Buenos días, ¿cómo estás? Hoy hace un tiempo estupendo.") == nil)
    }
}
