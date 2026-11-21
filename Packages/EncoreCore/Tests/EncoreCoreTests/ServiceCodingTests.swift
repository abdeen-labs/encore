import Foundation
import Testing
@testable import EncoreCore

/// Every request, event and result type survives JSON — the wire format for the future local HTTP API.
@Suite struct ServiceCodingTests {
    func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func json<T: Codable & Equatable>(_ value: T) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    @Test func requestsRoundTrip() throws {
        var speech = SpeechRequest(modelID: "kokoro", text: "Hello [pause 1s] world")
        speech.variantID = "bf16"; speech.voice = .preset("af_heart"); speech.instruct = "calm"; speech.language = "en"
        speech.parameters = ["speed": .double(1.1), "seed": .int(3), "flag": .bool(true), "mode": .string("x")]
        speech.post.removeSilence = true; speech.post.targetLUFS = -20; speech.autoChunk = false
        speech.applyPronunciations = false; speech.chunkGapSeconds = 0.3; speech.title = "T"
        let s2 = try roundTrip(speech)
        let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
        #expect(try sorted.encode(s2) == sorted.encode(speech))

        var t = TranscriptionRequest(modelID: "whisper", mediaPath: "/tmp/a.mp4")
        t.timestamps = .word; t.language = "fr"; t.parameters = ["temperature": .double(0.2)]
        let t2 = try roundTrip(t)
        #expect(t2.timestamps == .word && t2.language == "fr" && t2.parameters == t.parameters && t2.mediaPath == t.mediaPath)

        let id = UUID()
        var c = VoiceConversionRequest(modelID: "vc", sourcePath: "/a.wav", voice: .library(id))
        c.post.normalizeLoudness = false; c.title = "x"
        let c2 = try roundTrip(c)
        #expect(c2.voice == .library(id) && c2.post == c.post && c2.title == "x")

        var d = VoiceDesignRequest(modelID: "q", description: "warm", sampleText: "hi")
        d.candidates = 5; d.parameters = ["seed": .int(1)]
        let d2 = try roundTrip(d)
        #expect(d2.candidates == 5 && d2.description == "warm" && d2.parameters == d.parameters)

        var script = ConversationScript()
        script.title = "Talk"
        let a = ConversationScript.Speaker(name: "A")
        script.speakers = [a]
        var line = ConversationScript.Line(speakerID: a.id, text: "Hi")
        line.pauseAfter = 0.8
        script.lines = [line]
        var conv = ConversationRequest(modelID: "q", script: script)
        conv.pauseSeconds = 0.2; conv.reuseRenderedLines = false
        let conv2 = try roundTrip(conv)
        #expect(conv2.script == script && conv2.pauseSeconds == 0.2 && !conv2.reuseRenderedLines)
    }

    @Test func minimalBodiesDecodeWithDefaults() throws {
        let s = try JSONDecoder().decode(SpeechRequest.self, from: Data(#"{"modelID":"kokoro","text":"Hi"}"#.utf8))
        #expect(s.voice == .automatic && s.autoChunk && s.applyPronunciations && s.post == PostProcessingOptions() && s.parameters.isEmpty)
        let p = try JSONDecoder().decode(SpeechRequest.self, from: Data(#"{"modelID":"k","text":"Hi","voice":{"preset":"af_heart"},"post":{"removeSilence":true}}"#.utf8))
        #expect(p.voice == .preset("af_heart") && p.post.removeSilence && p.post.normalizeLoudness)
        let id = UUID()
        let l = try JSONDecoder().decode(VoiceConversionRequest.self,
                                         from: Data(#"{"modelID":"vc","sourcePath":"/a.wav","voice":{"library":"\#(id.uuidString)"}}"#.utf8))
        #expect(l.voice == .library(id))
        let auto = try JSONDecoder().decode(SpeechRequest.self, from: Data(#"{"modelID":"k","text":"Hi","voice":"automatic"}"#.utf8))
        #expect(auto.voice == .automatic)
        let t = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(#"{"modelID":"w","mediaPath":"/a.mp3"}"#.utf8))
        #expect(t.timestamps == .segment)
        let d = try JSONDecoder().decode(VoiceDesignRequest.self, from: Data(#"{"modelID":"q","description":"d","sampleText":"s"}"#.utf8))
        #expect(d.candidates == 3)
        let speaker = UUID()
        let c = try JSONDecoder().decode(ConversationRequest.self, from: Data("""
            {"modelID":"q","script":{"speakers":[{"id":"\(speaker.uuidString)","name":"A","voice":{"preset":"p"}}],
             "lines":[{"speakerID":"\(speaker.uuidString)","text":"Hello"}]}}
            """.utf8))
        #expect(c.script.lines.count == 1 && c.pauseSeconds == 0.4 && c.reuseRenderedLines && c.script.speakers[0].voice == .preset("p"))
    }

    @Test func voiceSelectionKeepsItsEncodingAndReadsBothForms() throws {
        let id = UUID()
        for v: VoiceSelection in [.automatic, .preset("x"), .library(id)] { #expect(try roundTrip(v) == v) }
        // The synthesized form other code may have stored still decodes.
        let stored = try JSONDecoder().decode(VoiceSelection.self, from: Data(#"{"preset":{"_0":"x"}}"#.utf8))
        #expect(stored == .preset("x"))
        #expect(try json(VoiceSelection.preset("x")) == #"{"preset":{"_0":"x"}}"#)
    }

    @Test func eventsAndResultsRoundTrip() throws {
        let record = GenerationRecord(kind: .conversation, title: "T", text: "A: hi", modelID: "m", modelName: "M", voiceName: "A, B",
                                      parameters: ["seed": .int(1)], audioPath: "/x.wav", duration: 2.5, sampleRate: 24_000, elapsed: 1.2)
        for e: GenerationEvent in [.stage("Generating 1 of 2"), .progress(0.25), .finished(record)] {
            let back = try roundTrip(e)
            switch (e, back) {
            case (.stage(let a), .stage(let b)): #expect(a == b)
            case (.progress(let a), .progress(let b)): #expect(a == b)
            case (.finished(let a), .finished(let b)): #expect(a == b)
            default: Issue.record("mismatch \(e) \(back)")
            }
        }
        let tr = TranscriptionRecord(sourceName: "a.mp4", sourcePath: "/a.mp4", modelID: "w", modelName: "W",
                                     transcript: Transcript(text: "hi", language: "en", duration: 1,
                                                            segments: [.init(id: 0, start: 0, end: 1, text: "hi", words: [.init(start: 0, end: 0.4, text: "hi")])]))
        if case .finished(let b) = try roundTrip(TranscriptionEvent.finished(tr)) { #expect(b == tr && b.transcript == tr.transcript) }
        else { Issue.record("transcription event") }
        let cand = VoiceDesignCandidate(audioPath: "/c.wav", transcript: "s", description: "d", modelID: "q", duration: 2, seed: 9)
        if case .candidate(let b) = try roundTrip(VoiceDesignEvent.candidate(cand)) { #expect(b == cand) } else { Issue.record("candidate") }
        if case .finished = try roundTrip(VoiceDesignEvent.finished) {} else { Issue.record("finished") }
        // Old candidates without a seed still decode.
        let old = try JSONDecoder().decode(VoiceDesignCandidate.self, from: Data(
            #"{"id":"\#(UUID().uuidString)","audioPath":"/c.wav","transcript":"s","description":"d","modelID":"q","duration":2}"#.utf8))
        #expect(old.seed == nil)

        #expect(String(decoding: try JSONEncoder().encode(GenerationEvent.progress(0.5)), as: UTF8.self).contains(#""type":"progress""#))
    }

    @Test func runtimeTypesRoundTrip() throws {
        let snap = RuntimeSnapshot(loaded: [LoadedModel(modelID: "m", modelName: "M", variantID: "v", variantLabel: "V", runtime: .python,
                                                        memoryBytes: 5, loadedAt: Date(timeIntervalSince1970: 1), lastUsed: Date(timeIntervalSince1970: 2),
                                                        isBusy: true, unloadsAt: nil)],
                                   jobs: [JobStatus(id: UUID(), kind: .speech, title: "t", modelID: "m", modelName: "M", state: .running,
                                                    stage: "s", progress: 0.5, runtime: .mlxSwift, enqueuedAt: Date(timeIntervalSince1970: 3))],
                                   memory: SystemMemory(physicalBytes: 10, availableBytes: 5, pressure: .warning), version: 4)
        #expect(try roundTrip(snap) == snap)
        let a = MemoryAssessment(verdict: .tight, modelID: "m", variantID: "v", requiredBytes: 1, memory: snap.memory, loadedBytes: 0,
                                 evictableBytes: 0, budgetBytes: 7, headroomBytes: 1, alreadyLoaded: false, wouldUnload: [])
        #expect(try roundTrip(a) == a)
    }

    @Test func serviceErrorsHaveCodesAndMessages() {
        let errors: [ServiceError] = [
            .unknownModel("x"), .wrongTask(modelID: "w", modelName: "W", task: .tts),
            .modelNotDownloaded(modelID: "m", variantID: "v", modelName: "M", variantLabel: "V", partial: true),
            .backendNeedsSetup(runtime: .python, message: "m"), .backendUnavailable(runtime: .python, message: "m"),
            .featureUnsupported(modelID: "m", modelName: "M", feature: .cloning, detail: nil), .voiceMissing("v"),
            .unknownPresetVoice(name: "n", modelID: "m"), .unknownVoiceTags(["a"]), .emptyScript, .scriptProblem("p"),
            .sourceUnreadable(path: "/a", reason: "r"), .noTranscriptionModel, .invalidRequest("i"), .generationFailed("g"),
        ]
        #expect(Set(errors.map(\.code)).count == errors.count)
        #expect(errors.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }
}
