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
        let events = try await collect(w.service.renderConversation(r))
        #expect(backend.synthCalls.count == 5)
        #expect(backend.synthCalls.last?.text == "Hi Ann! How have you been?")
        #expect(stages(events).contains("Reused 2 unchanged lines"))
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

    @Test func designOnAModelWithoutDesignIsATypedError() async throws {
        let w = try ServiceWorld(models: [Self.speaker], backends: [FakeBackend(.mlxSwift, features: ["speaker": .synthesis])])
        await #expect(throws: ServiceError.featureUnsupported(modelID: "speaker", modelName: "Speaker", feature: .voiceDesign,
                                                              detail: "Pick a model that designs voices, such as Qwen3-TTS VoiceDesign.")) {
            _ = try await collect(w.service.designVoice(VoiceDesignRequest(modelID: "speaker", description: "x", sampleText: "y")))
        }
    }

    @Test func cancelledDesignDeletesItsCandidates() async throws {
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
        #expect(stages(events).contains { $0.hasPrefix("Converting 2 of") })

        r.voice = .automatic
        await #expect(throws: ServiceError.invalidRequest("Pick the voice to change to.")) { _ = try await collect(w.service.convertVoice(r)) }
    }
}
