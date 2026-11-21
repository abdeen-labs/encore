#if DEBUG
import EncoreCore
import Foundation

/// The models the headless proofs run on: the smallest in the catalog that can do each job, so a proof run stays
/// light on the machine. Nothing is named here; "smallest" is read from the manifests' download sizes. A proof
/// that needs a larger model has to be asked for one explicitly (`--model`).
@MainActor
enum ProofModels {
    /// A model's size: its smallest variant's download.
    static func size(_ m: ModelManifest) -> Int64 { m.variants.map(\.downloadBytes).min() ?? .max }

    /// The smallest model for `task` that passes `test`.
    static func smallest(_ catalog: ModelCatalog, _ task: ModelTask, where test: (ModelManifest) -> Bool = { _ in true }) -> ModelManifest? {
        catalog.models(for: task).filter(test).min { size($0) < size($1) }
    }

    /// Plain speech, any voice.
    static func speech(_ c: ModelCatalog) -> ModelManifest? { smallest(c, .tts) }
    /// Several preset voices to cast (conversations, voice filters, a source and a target for the changer).
    static func speakers(_ c: ModelCatalog) -> ModelManifest? { smallest(c, .tts) { $0.presetVoices.count >= 4 } }
    static func cloning(_ c: ModelCatalog) -> ModelManifest? { smallest(c, .tts) { $0.capabilities.cloning } }
    static func design(_ c: ModelCatalog) -> ModelManifest? { smallest(c, .tts) { $0.capabilities.voiceDesign } }
    static func transcription(_ c: ModelCatalog) -> ModelManifest? { smallest(c, .stt) }
    static func voiceChange(_ c: ModelCatalog) -> ModelManifest? { smallest(c, .voiceConversion) }

    static func model(for feature: AppSettings.Feature, in c: ModelCatalog) -> ModelManifest? {
        switch feature {
        case .speech: speech(c)
        case .cloning: cloning(c)
        case .voiceDesign: design(c)
        case .conversation: speakers(c)
        case .voiceChange: voiceChange(c)
        case .transcription: transcription(c)
        }
    }

    /// Points each feature's "last used model" at the smallest capable one, which is where every screen's model
    /// (and the service's default transcription model) starts. Returns what isn't downloaded yet, as
    /// "Name (size)": a proof should stop and say so, because a screen would otherwise fall back to whatever
    /// larger model happens to be on disk.
    static func seed(_ settings: AppSettings, catalog: ModelCatalog, shelf: ModelShelf,
                     features: [AppSettings.Feature] = AppSettings.Feature.allCases,
                     also extra: [ModelManifest?] = []) -> [String] {
        var needed: [ModelManifest] = []
        for feature in features {
            guard let m = model(for: feature, in: catalog) else { continue }
            settings.noteModelUsed(m.id, for: feature)
            needed.append(m)
        }
        needed += extra.compactMap { $0 }
        var missing: [String] = []
        for m in needed where !shelf.isAnyVariantDownloaded(m) {
            let label = "\(m.name) (\(ByteCountFormatter.string(fromByteCount: size(m), countStyle: .file)))"
            if !missing.contains(label) { missing.append(label) }
        }
        return missing
    }

    /// The model and the variant of it that is on disk (the smallest one, if none is).
    static func choice(_ m: ModelManifest, shelf: ModelShelf) -> ModelChoice {
        let onDisk = m.variants.filter { shelf.isDownloaded(m, variantID: $0.id) }
        let pick = (onDisk.isEmpty ? m.variants : onDisk).min { $0.downloadBytes < $1.downloadBytes }
        return ModelChoice(modelID: m.id, variantID: pick?.id)
    }

    /// Preset voice number `index` of `m` (wrapping), or the model's own voice when it has no presets.
    static func voice(_ index: Int, of m: ModelManifest) -> VoiceSelection {
        m.presetVoices.isEmpty ? .automatic : .preset(m.presetVoices[index % m.presetVoices.count].id)
    }
}
#endif
