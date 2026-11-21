#if DEBUG
import EncoreCore
import SwiftUI

/// Made-up states for the Models and Settings screens, rendered by `--snapshot` (names start with
/// `Models-` / `Settings-`). Fixtures never read the user's token, Keychain or model cache: they only
/// write fixture values into the snapshot's throwaway `AppDependencies`.
///
///     Encore --snapshot <dir> --snapshot-only Models-Mixed,Models-Details,Settings-SignedIn
struct FeatureFixture {
    struct Overrides {
        var library: ModelsLibrary?
        var settingsModel: SettingsModel?
    }

    let name: String
    let section: AppSection
    /// nil: the default window size.
    var size: CGSize?
    let prepare: @MainActor (AppDependencies) -> Overrides
    /// A sheet's content rendered on its own (sheets aren't part of the window capture); nil renders the window.
    var sheet: (@MainActor (AppDependencies, Overrides) -> AnyView)?
    /// Async setup that runs before `prepare` (e.g. writing records into the snapshot's throwaway history).
    var seed: (@MainActor (AppDependencies) async -> Void)?

    static let minimum = CGSize(width: 940, height: 600)

    static var all: [FeatureFixture] {
        [
            FeatureFixture(name: "Models-Mixed", section: .models, prepare: { mixedModels($0) }),
            FeatureFixture(name: "Models-Mixed-Min", section: .models, size: minimum, prepare: { mixedModels($0) }),
            FeatureFixture(name: "Models-Mixed-Tall", section: .models, size: CGSize(width: 1180, height: 3000), prepare: { mixedModels($0) }),
            FeatureFixture(name: "Models-Details-Tall", section: .models, size: CGSize(width: 680, height: 1500),
                           prepare: { mixedModels($0) },
                           sheet: { deps, o in AnyView(ModelDetailView(manifest: deps.catalog.model("omnivoice")!, library: o.library!,
                                                                       onGetAccess: { _ in }, scrollHeight: 1350)) }),
            FeatureFixture(name: "Models-Details", section: .models, size: CGSize(width: 680, height: 600),
                           prepare: { mixedModels($0) },
                           sheet: { deps, o in AnyView(ModelDetailView(manifest: deps.catalog.model("omnivoice")!, library: o.library!) { _ in }) }),
            FeatureFixture(name: "Models-Details-Variants", section: .models, size: CGSize(width: 680, height: 600),
                           prepare: { mixedModels($0) },
                           sheet: { deps, o in AnyView(ModelDetailView(manifest: deps.catalog.model("qwen3-tts-base")!, library: o.library!) { _ in }) }),
            FeatureFixture(name: "Models-Details-Gated", section: .models, size: CGSize(width: 680, height: 600),
                           prepare: { mixedModels($0) },
                           sheet: { deps, o in AnyView(ModelDetailView(manifest: deps.catalog.model("orpheus")!, library: o.library!) { _ in }) }),
            FeatureFixture(name: "Models-Gate", section: .models, size: CGSize(width: 560, height: 600),
                           prepare: { deps in
                               let o = mixedModels(deps)
                               deps.hubAccount.showFixture(.signedIn(account), source: .keychain)
                               return o
                           },
                           sheet: { deps, o in AnyView(GateFlowView(request: gateRequest, manifest: deps.catalog.model("orpheus")!, library: o.library!)) }),
            FeatureFixture(name: "Models-Gate-NoToken", section: .models, size: CGSize(width: 560, height: 560),
                           prepare: { deps in
                               let o = mixedModels(deps)
                               deps.hubAccount.showFixture(.signedOut)
                               return o
                           },
                           sheet: { deps, o in AnyView(GateFlowView(request: gateRequest, manifest: deps.catalog.model("orpheus")!, library: o.library!)) }),
            FeatureFixture(name: "Settings-SignedOut", section: .settings, prepare: { deps in
                deps.hubAccount.showFixture(.signedOut)
                return Overrides(settingsModel: settingsModel(ffmpeg: false, python: .needsSetup(pythonSetupMessage)))
            }),
            FeatureFixture(name: "Settings-SignedOut-EncoreOnly", section: .settings, prepare: { deps in
                deps.hubAccount.showFixture(.signedOut, signedOutOfEncoreOnly: true)
                return Overrides(settingsModel: settingsModel(ffmpeg: true, python: pythonFound))
            }),
            FeatureFixture(name: "Settings-SignOutSheet", section: .settings, size: CGSize(width: 520, height: 420),
                           prepare: { deps in
                               deps.hubAccount.showFixture(.signedIn(account), source: .keychain)
                               return Overrides(settingsModel: settingsModel(ffmpeg: true, python: pythonFound))
                           },
                           sheet: { _, _ in AnyView(SignOutSheet(tokenPath: "~/.cache/huggingface/token", everywhere: {}, encoreOnly: {})) }),
            FeatureFixture(name: "Settings-SignedIn", section: .settings, prepare: { deps in
                deps.hubAccount.showFixture(.signedIn(account), source: .keychain)
                loadedModels(deps)
                return Overrides(settingsModel: settingsModel(ffmpeg: true, python: pythonFound, running: true))
            }),
            FeatureFixture(name: "Settings-SignedIn-Tall", section: .settings, size: CGSize(width: 1180, height: 2600), prepare: { deps in
                deps.hubAccount.showFixture(.signedIn(account), source: .keychain)
                loadedModels(deps)
                return Overrides(settingsModel: settingsModel(ffmpeg: true, python: pythonFound, running: true))
            }),
            FeatureFixture(name: "Settings-SignedOut-Tall", section: .settings, size: CGSize(width: 1180, height: 2600), prepare: { deps in
                deps.hubAccount.showFixture(.signedOut)
                return Overrides(settingsModel: settingsModel(ffmpeg: false, python: .needsSetup(pythonSetupMessage)))
            }),
            FeatureFixture(name: "Settings-Invalid-Min", section: .settings, size: minimum, prepare: { deps in
                deps.hubAccount.showFixture(.invalidToken, source: .keychain)
                return Overrides(settingsModel: settingsModel(ffmpeg: false, python: .needsSetup(pythonSetupMessage)))
            }),
            // The rail as it looks while Command is held.
            FeatureFixture(name: "Rail-ShortcutHints", section: .voices, prepare: { _ in Overrides() },
                           sheet: { _, _ in AnyView(RootView().environment(\.forcesShortcutHints, true)) }),
            FeatureFixture(name: "Rail-ShortcutHints-Min", section: .studio, size: minimum, prepare: { _ in Overrides() },
                           sheet: { _, _ in AnyView(RootView().environment(\.forcesShortcutHints, true)) }),
        ] + HistoryFixtures.all + VoiceFixtures.inspectorFixtures + ResetFixtures.all  // Features/History/HistoryFixtures.swift, Features/Voices/VoiceFixtures.swift, Features/Settings/ResetFixtures.swift
    }

    // MARK: Data

    static let account = HubAccount(name: "ada-l", fullName: "Ada Lovelace", tokenRole: "read", tokenName: "encore")
    static let gateRequest = GateRequest(modelID: "orpheus", variantID: "4bit", repo: "canopylabs/orpheus-3b-0.1-ft")
    static let pythonSetupMessage = "The Python runtime isn't set up. In the Encore repository, run Scripts/setup-python-runtime.sh, then try again."
    static let pythonFound = PythonRuntime.Lookup.found(PythonRuntime(executable: URL(fileURLWithPath: "/Applications/Encore.app/Contents/Resources/python/bin/python3"),
                                                                      helperRoot: URL(fileURLWithPath: "/Applications/Encore.app/Contents/Resources/PythonHelper"),
                                                                      origin: .bundled))

    @MainActor static func mixedModels(_ deps: AppDependencies) -> Overrides {
        let c = deps.catalog
        func key(_ id: String, _ variant: String? = nil) -> ModelVariantKey {
            let m = c.model(id)!
            return ModelVariantKey(m, m.variant(variant))
        }
        let GB: Int64 = 1_000_000_000
        var states: [ModelVariantKey: ModelDownloadState] = [:]
        for m in c.models { for v in m.variants { states[ModelVariantKey(m, v)] = .notDownloaded } }
        states[key("soprano")] = .downloaded(bytesOnDisk: 284_000_000)
        states[key("whisper-large-v3-turbo")] = .downloaded(bytesOnDisk: 1_620_000_000)
        states[key("chatterbox-turbo")] = .downloaded(bytesOnDisk: 1_200_000_000)
        let total = Int64(3.1 * Double(GB))
        states[key("qwen3-tts-base")] = .downloading(HubDownloadProgress(
            phase: .downloading, totalBytes: total, completedBytes: Int64(Double(total) * 0.37), bytesPerSecond: 23_400_000,
            activeFiles: [], totalFiles: 14, completedFiles: 9))
        states[key("voxcpm2")] = .partial(bytesOnDisk: Int64(1.4 * Double(GB)))
        states[key("orpheus")] = .failed(.gated(repo: "canopylabs/orpheus-3b-0.1-ft", kind: .auto,
                                                message: "Access to model canopylabs/orpheus-3b-0.1-ft is restricted."), bytesOnDisk: 0)
        states[key("parakeet-tdt-v3")] = .failed(.offline, bytesOnDisk: 820_000_000)
        deps.downloads.showFixture(states: states, totalBytesOnDisk: Int64(4.9 * Double(GB)))
        deps.hubAccount.showFixture(.signedIn(account), source: .keychain)
        loadedModels(deps)

        let library = ModelsLibrary()
        library.isFixture = true
        library.python = .needsSetup(pythonSetupMessage)
        for m in c.models {
            // As the real app plans them: these engines only run in the Python helper (MLXEngines.features lacks them).
            let python = ["chatterbox-vc", "chatterbox-multilingual"].contains(m.id)
            library.plans[m.id] = python ? .pythonUnavailable(pythonSetupMessage) : .native
            for v in m.variants {
                let verdict: MemoryAssessment.Verdict = v.memoryBytes > 10 * GB ? .wontFit : (v.memoryBytes > 8 * GB ? .tight : .comfortable)
                library.fits[ModelVariantKey(m, v)] = ModelsLibrary.Fit(verdict: verdict, summary: fitSummary(verdict, v.memoryBytes))
            }
        }
        library.fits[key("soprano")]?.alreadyLoaded = true
        library.licenses["omnivoice"] = .loaded(HubLicenseText(source: .modelCard, text: omniVoiceLicense,
                                                                url: URL(string: "https://huggingface.co/k2-fsa/OmniVoice")))
        library.licenses["qwen3-tts-base"] = .loading
        library.licenses["orpheus"] = .loaded(HubLicenseText(source: .standard("Apache-2.0"), text: apacheExcerpt,
                                                              url: URL(string: "https://huggingface.co/canopylabs/orpheus-3b-0.1-ft")))
        let orpheus = "canopylabs/orpheus-3b-0.1-ft"
        library.repoInfo["mlx-community/orpheus-3b-0.1-ft-4bit"] = HubRepoInfo(id: "mlx-community/orpheus-3b-0.1-ft-4bit", gate: .auto,
            licenseID: "apache-2.0", gatePrompt: orpheusPrompt, pageURL: URL(string: "https://huggingface.co/mlx-community/orpheus-3b-0.1-ft-4bit")!)
        library.gates["mlx-community/orpheus-3b-0.1-ft-4bit"] = .gated(kind: .auto, message: "Access is restricted.")
        library.repoInfo[orpheus] = HubRepoInfo(id: orpheus, gate: .auto, licenseID: "apache-2.0", gatePrompt: orpheusPrompt,
                                                pageURL: URL(string: "https://huggingface.co/\(orpheus)")!)
        library.gates[orpheus] = .gated(kind: .auto, message: "Access is restricted.")
        return Overrides(library: library)
    }

    static func fitSummary(_ verdict: MemoryAssessment.Verdict, _ bytes: Int64) -> String {
        let need = Bytes.memory(bytes)
        switch verdict {
        case .comfortable: return "Needs about \(need); 31.4 GB is free."
        case .tight: return "Needs about \(need) and only 9.8 GB is free. It will run, but macOS will compress or swap memory and everything slows down. Quitting other apps helps."
        case .wontFit: return "Needs about \(need) but only 9.8 GB is free. Quit other apps or pick a smaller variant."
        }
    }

    @MainActor static func loadedModels(_ deps: AppDependencies) {
        let now = Date().timeIntervalSinceReferenceDate
        let json: [String: Any] = [
            "version": 1_000_000,
            "jobs": [], "recentUnloads": [],
            "memory": ["physicalBytes": 51_539_607_552, "availableBytes": 33_700_000_000, "pressure": "normal"],
            "loaded": [
                ["modelID": "soprano", "modelName": "Soprano", "variantID": "bf16", "variantLabel": "bf16", "runtime": "mlxSwift",
                 "memoryBytes": 3_100_000_000, "loadedAt": now - 900, "lastUsed": now - 120, "isBusy": false, "unloadsAt": now + 480],
                ["modelID": "whisper-large-v3-turbo", "modelName": "Whisper Large v3 Turbo", "variantID": "fp16", "variantLabel": "fp16",
                 "runtime": "python", "memoryBytes": 2_400_000_000, "loadedAt": now - 60, "lastUsed": now, "isBusy": true],
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let snapshot = try? JSONDecoder().decode(RuntimeSnapshot.self, from: data) {
            deps.runtimeStatus.apply(snapshot)
        }
    }

    @MainActor static func settingsModel(ffmpeg: Bool, python: PythonRuntime.Lookup, running: Bool = false) -> SettingsModel {
        let m = SettingsModel()
        m.isFixture = true
        m.ffmpegChecked = true
        m.ffmpeg = ffmpeg ? URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg") : nil
        m.python = python
        if running { m.helper = .init(helperVersion: "0.4.0", pythonVersion: "3.13.9", mlxAudioVersion: "0.6.7") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        m.storage = [
            .init(title: "Models", detail: "Hugging Face cache", url: home.appendingPathComponent(".cache/huggingface/hub"), bytes: 4_900_000_000),
            .init(title: "History", detail: "Takes", url: home.appendingPathComponent("Library/Application Support/Encore/History"), bytes: 212_000_000),
            .init(title: "Voices", detail: "Voice library", url: home.appendingPathComponent("Library/Application Support/Encore/Voices"), bytes: 18_400_000),
        ]
        return m
    }

    static let orpheusPrompt = "By accessing this model you agree to use it lawfully and not to impersonate real people without their consent. Share your name and intended use so the authors can understand how Orpheus is used."

    static let omniVoiceLicense = "Our code is released under the Apache 2.0 License. The pre-trained model is licensed under the CC-BY-NC due to constraints from its training data (e.g., Emilia)."

    static let apacheExcerpt = """
    Apache License
    Version 2.0, January 2004
    http://www.apache.org/licenses/

    TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

    1. Definitions.

    "License" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.

    "Licensor" shall mean the copyright owner or entity authorized by the copyright owner that is granting the License.
    """
}
#endif
