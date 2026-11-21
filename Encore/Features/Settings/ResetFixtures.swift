#if DEBUG
import EncoreCore
import SwiftUI

/// Settings → Reset states for `--snapshot` (names start with `Settings-Reset`). Made-up counts only; nothing is
/// measured or deleted (the sheets don't act in fixtures).
///
///     Encore --snapshot <dir> --snapshot-only Settings-Reset,Settings-ResetAppData,Settings-ResetModels
@MainActor
enum ResetFixtures {
    static var all: [FeatureFixture] {
        let min = FeatureFixture.minimum
        var out: [FeatureFixture] = []
        for (suffix, size) in [("", nil), ("-Min", min)] as [(String, CGSize?)] {
            out.append(section("Settings-Reset" + suffix, size: size, outcome: nil))
            out.append(section("Settings-Reset-Done" + suffix, size: size, outcome: .appData(doneReport)))
            out.append(section("Settings-Reset-Failed" + suffix, size: size, outcome: .models(failedRemoval, modelCount: 5)))
            // Sheets on their own, in a canvas as tall as the window's room for a sheet.
            let canvas = CGSize(width: 540, height: size == nil ? 720 : 560)
            out.append(FeatureFixture(name: "Settings-ResetAppData" + suffix, section: .settings, size: canvas,
                                      prepare: { _ in .init() },
                                      sheet: { deps, _ in AnyView(sheetCanvas(ResetAppDataSheet(preset: inventory))) }))
            out.append(FeatureFixture(name: "Settings-ResetModels" + suffix, section: .settings, size: canvas,
                                      prepare: { _ in .init() },
                                      sheet: { deps, _ in AnyView(sheetCanvas(ResetModelsSheet(preset: plan(deps)))) }))
        }
        out.append(FeatureFixture(name: "Settings-ResetModels-Empty", section: .settings, size: CGSize(width: 540, height: 400),
                                  prepare: { _ in .init() },
                                  sheet: { deps, _ in AnyView(sheetCanvas(ResetModelsSheet(preset: emptyPlan))) }))
        return out
    }

    private static func section(_ name: String, size: CGSize?, outcome: ResetOutcome?) -> FeatureFixture {
        FeatureFixture(name: name, section: .settings, size: size, prepare: { deps in
            deps.hubAccount.showFixture(.signedIn(FeatureFixture.account), source: .keychain)
            return .init(settingsModel: FeatureFixture.settingsModel(ffmpeg: true, python: FeatureFixture.pythonFound))
        }, sheet: { _, _ in
            AnyView(RootView().environment(\.scaffoldScrollAnchor, .bottom).environment(\.resetOutcomeFixture, outcome))
        })
    }

    /// A sheet as it sits in the window: on the surface color, top-aligned.
    private static func sheetCanvas(_ sheet: some View) -> some View {
        sheet.background(Color.surface).frame(maxHeight: .infinity, alignment: .top).background(Color.backdrop)
    }

    // MARK: Data

    static let inventory: AppDataReset.Inventory = {
        var i = AppDataReset.Inventory()
        i.voices = 14; i.clonedVoices = 9; i.designedVoices = 4; i.importedVoices = 1
        i.historyItems = 312; i.presets = 6; i.pronunciations = 23
        i.historyBytes = 1_284_000_000; i.voiceBytes = 41_200_000; i.otherBytes = 18_700_000
        i.hasKeychainToken = true; i.settingsKeys = 11
        return i
    }()

    static let doneReport = AppDataReset.Report(removed: inventory, bytesFreed: 1_336_400_000, failures: [])

    static let failedRemoval = HubRemovalResult(
        removedRepos: ["mlx-community/Soprano-1.1-80M-bf16", "mlx-community/chatterbox-turbo-8bit", "mlx-community/S3TokenizerV2",
                       "mlx-community/whisper-large-v3-turbo-asr-fp16"],
        removedWorkingCopies: 2, bytesFreed: 4_812_000_000,
        failures: ["Couldn't delete mlx-community/VoxCPM2-8bit: “model.safetensors” couldn't be removed because you don't have permission to access it."])

    static func plan(_ deps: AppDependencies) -> ModelDownloadCenter.CatalogRemovalPlan {
        typealias M = ModelDownloadCenter.CatalogRemovalPlan.Model
        func m(_ id: String, _ variants: [(String, Bool)]) -> M {
            M(id: id, name: deps.catalog.model(id)?.name ?? id, variants: variants.map { .init(label: $0.0, complete: $0.1) })
        }
        let models = [m("chatterbox-multilingual", [("v3", true)]), m("chatterbox-vc", [("v3", true)]),
                      m("chatterbox-turbo", [("8-bit", true), ("4-bit", false)]), m("soprano", [("bf16", true)]),
                      m("qwen3-tts-base", [("1.7B · 8-bit", true), ("0.6B · 4-bit", true)]),
                      m("voxcpm2", [("8-bit", false)]), m("whisper-large-v3-turbo", [("fp16", true)])]
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return .init(models: models, sharedComponents: ["mlx-community/S3TokenizerV2"],
                     otherRepos: ["csukuangfj/sherpa-onnx-whisper-tiny", "facebook/nllb-200-distilled-600M", "mlx-community/snac_24khz"],
                     hub: HubRemovalPlan(repos: Array(repeating: "x", count: 9), workingCopies: [], bytes: 17_940_000_000))
    }

    static let emptyPlan = ModelDownloadCenter.CatalogRemovalPlan(models: [], sharedComponents: [], otherRepos: ["facebook/nllb-200-distilled-600M"],
                                                                  hub: HubRemovalPlan(repos: [], workingCopies: [], bytes: 0))
}
#endif
