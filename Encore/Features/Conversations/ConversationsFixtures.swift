#if DEBUG
import EncoreCore
import SwiftUI

/// Conversations snapshot states, DEBUG only, on snapshot mode's throwaway stores:
///
///     Encore --snapshot <dir> --snapshot-only Conversations --conversations-fixture imported [--snapshot-size 940x600]
///
/// States: empty, imported, editing, rendering, result, notes, unnamed, cloning, firstRun.
@MainActor
enum ConversationsFixtures {
    static var state: String? { ProduceFixtureSeed.arg("--conversations-fixture") }
    static var isRequested: Bool { state != nil }

    /// A short screenplay in the usual layout (also what the headless run prints into a PDF).
    static let screenplay = """
    THE LIGHTHOUSE KEEPER

    EXT. HARBOR WALL - NIGHT

    Rain. A single lamp swings above the dock. MIRA waits, coat pulled tight.

                        MIRA
              (to herself)
              Eleven years. He said he'd come back
              when the light went out. [pause 0.6s]

    Footsteps. TOM steps out of the dark, lantern in hand.

                        TOM
              The light never went out, Mira. I kept
              it burning every single night.

                        MIRA
              Then why didn't you come home?

                        TOM
              Because someone had to keep it burning.

                        JUNIPER (V.O.)
              Harbor control to the keeper. Storm
              front in twenty minutes. Do you copy?

                        TOM
              (into the radio)
              I copy, Juniper. Light's steady.

                        MIRA
              You haven't changed at all.

                        TOM
              Neither has the sea.

                        JUNIPER (V.O.)
              Keeper, the last ferry is still out.
              Keep that lamp high.

                        MIRA
              Then let me help you. [pause 0.4s] Just
              for tonight.

    They climb the stairs together. The beam sweeps the water.
    """

    static let paragraphs = """
    I never meant to stay this long. The town was only supposed to be a stop on the way north.

    You say that every winter. And every winter the ferry stops running and here you are.

    Maybe the ferry is the only honest thing in this place.

    Then buy a ticket in the spring. I'll even drive you to the dock.
    """

    static func prepare(_ deps: AppDependencies) async {
        guard let state else { return }
        if state != "firstRun" {
            await ProduceFixtureSeed.markDownloaded(deps, ["zonos3-mini", "chatterbox-turbo", "qwen3-tts-base"],
                                                    runtimes: ["zonos3-mini": .mlxSwift, "chatterbox-turbo": .mlxSwift, "qwen3-tts-base": .mlxSwift])
        }
        let cast = state == "cloning" || state == "result" ? await ProduceFixtureSeed.addVoices(deps) : nil
        let model = deps.screenModel("Conversations") { ConversationsModel(deps: deps) }
        await model.prepare()
        let zonos = ModelChoice(modelID: "zonos3-mini", variantID: "bf16")
        model.debugSet(choice: zonos, pause: 0.45)

        func importScreenplay() {
            model.apply(ConversationImporter.parse(screenplay), fileName: "The Lighthouse Keeper.pdf")
        }

        switch state {
        case "imported":
            importScreenplay()
            model.debugMarkRendered(model.lines.prefix(4).map(\.id))
        case "editing":
            importScreenplay()
            model.dismissImportReport()
            model.debugMarkRendered(model.lines.map(\.id))
            if model.lines.count > 3 {
                model.setText("Then why didn't you come home? [pause 0.5s] Not one letter.\nNot one.", for: model.lines[2].id)
                model.setPause(1.2, after: model.lines[2].id)
                model.editingLineID = model.lines[2].id
            }
        case "rendering":
            importScreenplay()
            model.dismissImportReport()
            let ids = model.lines.map(\.id)
            model.debugMarkRendered(Array(ids.prefix(3)))
            model.runner.debugShow(.running, identity: .init(kind: .conversation, modelID: "zonos3-mini", modelName: "Zonos3 Mini"),
                                   stage: "Line 5 of \(ids.count) (Tom)", progress: 0.9 * 4 / Double(ids.count),
                                   startedAt: Date().addingTimeInterval(-6))
        case "result":
            importScreenplay()
            model.dismissImportReport()
            if model.lines.count > 4 { model.setText("Then why didn't you come home? [pause 0.3s] Not once.", for: model.lines[2].id) }
            model.debugMarkRendered(model.lines.map(\.id))
            let r = await ProduceFixtureSeed.insertGeneration(deps, kind: .conversation, title: "The Lighthouse Keeper",
                                                              text: ConversationImporter.text(for: model.script), modelID: "zonos3-mini",
                                                              voiceName: "Mira, Tom, Juniper", seconds: 41, seed: 12, pitch: 170, ago: 30)
            model.debugShowResult(r, reused: model.lines.count - 1, lines: model.lines.count)
            model.result?.track.seek(to: 12.6)
            model.runner.debugShow(.idle, identity: nil, lastOutcome: .finished(elapsed: 2.4))
        case "notes":
            model.apply(ConversationImporter.parse(paragraphs), fileName: "Ferry, draft 2.txt")
        case "unnamed":
            model.pendingUnnamedImport = .init(result: ConversationImporter.parse(paragraphs), fileName: "Ferry, draft 2.txt")
        case "cloning":
            importScreenplay()
            model.dismissImportReport()
            if let cast, model.speakers.count >= 2 {
                model.setVoice(.library(cast.mira), for: model.speakers[0].id)
                model.setVoice(.library(cast.tom), for: model.speakers[1].id)
            }
        default:
            break
        }
        try? await Task.sleep(for: .milliseconds(300))
    }
}
#endif
