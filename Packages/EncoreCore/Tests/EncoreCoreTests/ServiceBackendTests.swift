import Foundation
import Testing
@testable import EncoreCore

/// Backend selection: by feature, by the user's runtime preference, availability, and run-time fallback.
@MainActor @Suite struct ServiceBackendTests {
    nonisolated static let speaker = testManifest("speaker", engine: "spk", capabilities: ["presetVoices": true, "cloning": true],
                                      presets: ["p1"])
    nonisolated static let whisper = testManifest("whisper-tiny", engine: "whisper", tasks: ["stt"],
                                      capabilities: ["segmentTimestamps": true, "wordTimestamps": true])

    func noPost() -> PostProcessingOptions { var p = PostProcessingOptions(); p.normalizeLoudness = false; return p }

    @Test func picksTheFirstBackendThatHasTheFeature() async throws {
        let native = FakeBackend(.mlxSwift, features: ["spk": .synthesis])
        let python = FakeBackend(.python, features: ["spk": [.synthesis, .cloning]])
        let w = try ServiceWorld(models: [Self.speaker], backends: [native, python])
        var r = SpeechRequest(modelID: "speaker", text: "Preset voice.")
        r.voice = .preset("p1")
        r.post = noPost()
        _ = try await collect(w.service.speak(r))
        #expect(native.synthCalls.count == 1 && python.synthCalls.isEmpty)

        let ava = try await w.addVoice("Ava")
        r.voice = .library(ava.id)
        _ = try await collect(w.service.speak(r))
        #expect(native.synthCalls.count == 1 && python.synthCalls.count == 1)
        #expect(await w.service.plannedRuntime(modelID: "speaker", needs: [.synthesis, .cloning]) == .success(.python))
        #expect(await w.service.plannedRuntime(modelID: "speaker") == .success(.mlxSwift))
    }

    @Test func userPreferenceMovesARuntimeFirst() async throws {
        let native = FakeBackend(.mlxSwift, features: ["spk": .synthesis])
        let python = FakeBackend(.python, features: ["spk": .synthesis])
        let w = try ServiceWorld(models: [Self.speaker], backends: [native, python])
        w.settings.setRuntimePreference(.python, for: "speaker")
        var r = SpeechRequest(modelID: "speaker", text: "Hello.")
        r.post = noPost()
        _ = try await collect(w.service.speak(r))
        #expect(python.synthCalls.count == 1 && native.synthCalls.isEmpty)
        #expect(await w.service.plannedRuntime(modelID: "speaker") == .success(.python))
        // A preference for a runtime that can't do it doesn't block the one that can.
        w.settings.setRuntimePreference(.mlxSwift, for: "speaker")
        python.setAvailability(.ready)
        #expect(await w.service.plannedRuntime(modelID: "speaker") == .success(.mlxSwift))
    }

    @Test func fallsThroughOnUnsupportedAtRunTime() async throws {
        let native = FakeBackend(.mlxSwift, features: ["whisper": .transcription])
        native.unsupportedWithoutLanguage = true
        let python = FakeBackend(.python, features: ["whisper": [.transcription, .wordTimestamps]])
        let w = try ServiceWorld(models: [Self.whisper], backends: [native, python])
        let media = try w.wav("talk.wav", Signal.speechLike(seconds: 3, rate: 44_100), rate: 44_100)
        let events = try await collect(w.service.transcribe(TranscriptionRequest(modelID: "whisper-tiny", mediaPath: media.path)))
        guard case .finished(let record)? = events.last else { Issue.record("no record"); return }
        #expect(native.transcribeCalls.count == 1 && python.transcribeCalls.count == 1)
        #expect(record.transcript.text == "Fake transcript.")
        // With a language the native port does it itself.
        var r = TranscriptionRequest(modelID: "whisper-tiny", mediaPath: media.path)
        r.language = "en"
        _ = try await collect(w.service.transcribe(r))
        #expect(native.transcribeCalls.count == 2 && python.transcribeCalls.count == 1)
    }

    @Test func unsupportedWithNoFallbackIsATypedError() async throws {
        let native = FakeBackend(.mlxSwift, features: ["whisper": .transcription])
        native.unsupportedWithoutLanguage = true
        let w = try ServiceWorld(models: [Self.whisper], backends: [native])
        let media = try w.wav("talk.wav", Signal.speechLike(seconds: 2, rate: 16_000), rate: 16_000)
        do {
            _ = try await collect(w.service.transcribe(TranscriptionRequest(modelID: "whisper-tiny", mediaPath: media.path)))
            Issue.record("expected an error")
        } catch let e as ServiceError {
            guard case .featureUnsupported(_, _, .transcription, "Needs a language.") = e else { Issue.record("\(e)"); return }
        }
        #expect(try await w.history.count() == 0)
        #expect(w.leftovers().isEmpty)
    }

    @Test func wordTimestampsNeedABackendThatHasThem() async throws {
        let native = FakeBackend(.mlxSwift, features: ["whisper": .transcription])
        let python = FakeBackend(.python, features: ["whisper": [.transcription, .wordTimestamps]])
        let w = try ServiceWorld(models: [Self.whisper], backends: [native, python])
        let media = try w.wav("talk.wav", Signal.speechLike(seconds: 2, rate: 16_000), rate: 16_000)
        var r = TranscriptionRequest(modelID: "whisper-tiny", mediaPath: media.path)
        r.timestamps = .word
        let events = try await collect(w.service.transcribe(r))
        #expect(native.transcribeCalls.isEmpty && python.transcribeCalls.count == 1)
        guard case .finished(let record)? = events.last else { Issue.record("no record"); return }
        #expect(record.transcript.segments.first?.words?.isEmpty == false)
        #expect(try await w.history.item(record.id)?.transcription?.transcript == record.transcript)

        // Only the native backend: word timestamps are a typed "unsupported".
        let w2 = try ServiceWorld(models: [Self.whisper], backends: [FakeBackend(.mlxSwift, features: ["whisper": .transcription])])
        await #expect(throws: ServiceError.featureUnsupported(modelID: "whisper-tiny", modelName: "Whisper-Tiny", feature: .wordTimestamps, detail: nil)) {
            _ = try await collect(w2.service.transcribe(r))
        }
    }

    @Test func backendNeedingSetupIsReported() async throws {
        let native = FakeBackend(.mlxSwift, features: ["spk": .synthesis])
        let python = FakeBackend(.python, features: ["spk": [.synthesis, .cloning]])
        python.setAvailability(.needsSetup("Install the Python helper."))
        let w = try ServiceWorld(models: [Self.speaker], backends: [native, python])
        let ava = try await w.addVoice("Ava")
        var r = SpeechRequest(modelID: "speaker", text: "Clone me.")
        r.voice = .library(ava.id)
        await #expect(throws: ServiceError.backendNeedsSetup(runtime: .python, message: "Install the Python helper.")) {
            _ = try await collect(w.service.speak(r))
        }
    }

    @Test func transcriptionPreparesAudioAndCleansUp() async throws {
        let b = FakeBackend(.mlxSwift, features: ["whisper": .transcription])
        let w = try ServiceWorld(models: [Self.whisper], backends: [b])
        let media = try w.wav("interview.wav", Signal.speechLike(seconds: 3, rate: 48_000), rate: 48_000)
        let events = try await collect(w.service.transcribe(TranscriptionRequest(modelID: "whisper-tiny", mediaPath: media.path)))
        guard case .finished(let record)? = events.last else { Issue.record("no record"); return }
        #expect(record.sourceName == "interview.wav" && record.modelName == "Whisper-Tiny")
        #expect(abs((record.transcript.duration ?? 0) - 3) < 0.01)
        let job = try #require(b.transcribeCalls.first)
        #expect(job.timestamps == .segment)
        #expect(!FileManager.default.fileExists(atPath: job.audio.path))  // the 16 kHz WAV was temporary
        #expect(w.leftovers().isEmpty)

        let reference = try await w.service.transcribeReference(media, range: 0...1.5)
        #expect(reference.text == "Fake transcript.")
        #expect(abs((reference.duration ?? 0) - 1.5) < 0.01)
        #expect(try await w.history.count() == 1)  // the reference transcription isn't saved
    }
}
