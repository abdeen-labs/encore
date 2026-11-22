#if DEBUG
import EncoreCore
import SwiftUI

/// Changer snapshot states, DEBUG only, on snapshot mode's throwaway stores:
///
///     Encore --snapshot <dir> --snapshot-only Changer --changer-fixture result [--snapshot-size 940x600]
///
/// States: empty, noVoices, ready, converting, result, helper, firstRun.
@MainActor
enum ChangerFixtures {
    static var state: String? { ProduceFixtureSeed.arg("--changer-fixture") }

    static func prepare(_ deps: AppDependencies) async {
        guard let state else { return }
        if state != "firstRun" {
            await ProduceFixtureSeed.markDownloaded(deps, ["chatterbox-vc", "zonos3-mini"], runtimes: ["chatterbox-vc": .python, "zonos3-mini": .mlxSwift])
        }
        let cast: ProduceFixtureSeed.Cast? = state == "noVoices" || state == "firstRun" ? nil : await ProduceFixtureSeed.addVoices(deps)
        let model = deps.screenModel("Changer") { ChangerModel(deps: deps) }
        model.pythonOverride = state == "helper"
            ? .needsSetup("The Python runtime isn't set up. In the Encore repository, run scripts/setup-python-runtime.sh, then try again.")
            : .found(PythonRuntime(executable: URL(fileURLWithPath: "/usr/bin/true"), helperRoot: URL(fileURLWithPath: "/tmp"), origin: .bundled))
        await model.prepare()
        let vc = ModelChoice(modelID: "chatterbox-vc", variantID: "multilingual-v3")

        func source(_ name: String, seconds: Double) async {
            let url = ProduceFixtureSeed.audio(deps, name: name, seconds: seconds, seed: 7, pitch: 150)
            let info = try? await AudioReader.probe(url)
            let pieces = try? await SpeechSegmenter.segment(fileAt: url, options: ChangerModel.segmentOptions(model.pieceSeconds))
            model.debugSetSource(url, info: info, pieces: pieces)
        }

        switch state {
        case "empty":
            model.debugSet(choice: vc, voiceID: cast?.mira)
        case "noVoices":
            model.debugSet(choice: vc, voiceID: nil)
            await source("Interview take 3.wav", seconds: 27)
        case "ready", "helper":
            model.debugSet(choice: vc, voiceID: cast?.captain)
            await source("Interview take 3.wav", seconds: 47)
        case "converting":
            model.debugSet(choice: vc, voiceID: cast?.juniper)
            await source("Lecture, full recording.m4a.wav", seconds: 212)
            let n = model.source?.pieces?.count ?? 10
            model.runner.debugShow(.running, identity: .init(kind: .voiceConversion, modelID: "chatterbox-vc", modelName: "Chatterbox Voice Changer"),
                                   stage: "Converting 5 of \(n)", progress: 0.05 + 0.85 * 4 / Double(n), startedAt: Date().addingTimeInterval(-38))
        case "result":
            model.debugSet(choice: vc, voiceID: cast?.captain)
            await source("Interview take 3.wav", seconds: 47)
            for (i, t) in [("Voicemail greeting.m4a", "Mira", 9.0), ("Podcast intro.wav", "Old Tom", 31.0), ("Audition, scene 2.wav", "Juniper", 64.0)].enumerated() {
                await ProduceFixtureSeed.insertGeneration(deps, kind: .voiceChange, title: "Voice change · \(t.0)", text: t.0, modelID: "chatterbox-vc",
                                                          voiceName: t.1, seconds: t.2, seed: 30 + i, pitch: [200, 100, 175][i], ago: Double(i + 1) * 5400)
            }
            let r = await ProduceFixtureSeed.insertGeneration(deps, kind: .voiceChange, title: "Voice change · Interview take 3",
                                                              text: "Interview take 3.wav", modelID: "chatterbox-vc", voiceName: "Captain Reyes",
                                                              voiceID: cast?.captain, seconds: 47, seed: 9, pitch: 112, ago: 20)
            model.show(r, original: model.source?.url)
            model.result?.track.seek(to: 17.4)
            model.result?.original?.seek(to: 17.4)
            model.runner.debugShow(.idle, identity: nil, lastOutcome: .finished(elapsed: 21.6))
        default:
            break
        }
        try? await Task.sleep(for: .milliseconds(300))
    }
}
#endif
