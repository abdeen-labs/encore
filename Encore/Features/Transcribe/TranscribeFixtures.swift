#if DEBUG
import EncoreCore
import SwiftUI

/// Transcribe snapshot states, DEBUG only, on snapshot mode's throwaway stores:
///
///     Encore --snapshot <dir> --snapshot-only Transcribe --transcribe-fixture result [--snapshot-size 940x600]
///
/// States: empty, ready, words-setup, running, result, words, hidden, export, firstRun.
@MainActor
enum TranscribeFixtures {
    static var state: String? { ProduceFixtureSeed.arg("--transcribe-fixture") }
    static var isRequested: Bool { state != nil }
    /// The export panel starts open.
    static var openExport: Bool { state == "export" }

    static let lines: [String] = [
        "Okay, everyone, from the top of act two, please.",
        "Places. Lights are going to come up slowly on the harbor.",
        "Mira, you're already on the dock when the lights come up.",
        "And remember, you haven't seen the captain in eleven years.",
        "So the first line is quiet. Almost to yourself.",
        "Tom, your entrance is on the second bell, not the first.",
        "We lost a beat there last night and the whole scene sped up.",
        "Let the silence sit. The audience will lean in if you let them.",
        "Sound, can we get the gulls a little lower under the dialogue?",
        "Good. Juniper, the radio voice comes from the back of the house.",
        "It should feel like it's drifting in from somewhere far away.",
        "Right. Let's run it, and we'll stop only if something breaks.",
        "Thank you. Going in three, two…",
    ]

    static func transcript(duration: Double, words: Bool) -> Transcript {
        var segments: [Transcript.Segment] = []
        var t = 0.6
        let total = Double(lines.reduce(0) { $0 + $1.count })
        let speech = duration - 0.6 - Double(lines.count) * 0.55
        for (i, line) in lines.enumerated() {
            let d = speech * Double(line.count) / total
            var ws: [Transcript.Word]?
            if words {
                let parts = line.split(separator: " ").map(String.init)
                let chars = Double(parts.reduce(0) { $0 + $1.count + 1 })
                var wt = t
                ws = parts.map { w in
                    let wd = d * Double(w.count + 1) / chars
                    defer { wt += wd }
                    return Transcript.Word(start: wt, end: wt + wd * 0.88, text: w)
                }
            }
            segments.append(.init(id: i, start: t, end: t + d, text: line, words: ws))
            t += d + 0.55
        }
        return Transcript(text: lines.joined(separator: " "), language: "en", duration: duration, segments: segments)
    }

    static func prepare(_ deps: AppDependencies) async {
        guard let state else { return }
        if state != "firstRun" {
            await ProduceFixtureSeed.markDownloaded(deps, ["whisper-large-v3-turbo", "parakeet-tdt-v3"],
                                                    runtimes: ["whisper-large-v3-turbo": .mlxSwift, "parakeet-tdt-v3": .mlxSwift])
        }
        // Earlier transcriptions.
        let earlier: [(String, String, Double)] = [
            ("Board meeting, 14 Nov.m4a", "Thanks everyone for joining. First item is the budget for next quarter, which Sam will walk us through.", 1834),
            ("Voice memo 0412.m4a", "Remember to call the venue about the load-in time, and ask whether the piano has been tuned.", 48),
            ("Interview with the director.mp4", "I always start with the sound of a room before I think about how it looks.", 2710),
            ("Lecture 6 — acoustics.mov", "Reverberation time depends on the volume of the room and how much of its surface absorbs sound.", 3402),
        ]
        for (i, e) in earlier.enumerated() {
            let r = TranscriptionRecord(sourceName: e.0, sourcePath: "/Volumes/Archive/\(e.0)", modelID: "whisper-large-v3-turbo",
                                        modelName: "Whisper Large v3 Turbo",
                                        transcript: Transcript(text: e.1, language: "en", duration: e.2,
                                                               segments: [.init(id: 0, start: 0, end: min(e.2, 9), text: e.1)]),
                                        createdAt: Date().addingTimeInterval(-Double(i + 1) * 86_000), elapsed: e.2 * 0.05)
            try? await deps.service.history.insert(r)
        }
        let model = deps.screenModel("Transcribe") { TranscribeModel(deps: deps) }
        await model.prepare()
        let whisper = ModelChoice(modelID: "whisper-large-v3-turbo", variantID: "fp16")
        let url = ProduceFixtureSeed.audio(deps, name: "Rehearsal, act two.wav", seconds: 62, seed: 4, pitch: 160)
        let info = try? await AudioReader.probe(url)

        switch state {
        case "empty":
            model.debugSet(choice: whisper)
        case "ready":
            model.debugSet(choice: whisper)
            model.debugSetSource(url, info: info)
        case "words-setup":
            model.debugSet(choice: whisper, timestamps: .word)
            model.debugSetSource(url, info: info)
            deps.modelShelf.runtimeOverrides["whisper-large-v3-turbo"] = .runs(.python)
        case "running":
            model.debugSet(choice: whisper, language: "en")
            model.debugSetSource(url, info: info)
            model.runner.debugShow(.running, identity: .init(kind: .transcription, modelID: "whisper-large-v3-turbo", modelName: "Whisper Large v3 Turbo"),
                                   stage: "Transcribing", progress: 0.42, startedAt: Date().addingTimeInterval(-7))
        case "result", "words", "hidden", "export":
            let words = state == "words"
            model.debugSet(choice: whisper, timestamps: words ? .word : .segment)
            model.debugSetSource(url, info: info)
            let record = TranscriptionRecord(sourceName: url.lastPathComponent, sourcePath: url.path, modelID: "whisper-large-v3-turbo",
                                             modelName: "Whisper Large v3 Turbo", transcript: transcript(duration: 62, words: words),
                                             elapsed: 4.8)
            try? await deps.service.history.insert(record)
            model.open(record)
            if state == "hidden" { model.showTimings = false }
            let seg = record.transcript.segments[words ? 3 : 5]
            let at = words ? (seg.words?[5].start ?? seg.start) + 0.05 : seg.start + 1.2
            model.recordTrack?.seek(to: at)
            model.runner.debugShow(.idle, identity: nil, lastOutcome: .finished(elapsed: 4.8))
        default:
            break
        }
        try? await Task.sleep(for: .milliseconds(300))
    }
}
#endif
