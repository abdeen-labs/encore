import EncoreCore
import Foundation

extension StudioModel {
    /// Casts a library voice (from Voices, Clone or Design). The Studio moves to a downloaded cloning model when
    /// its current one can't clone: `preferredModel` if it is on disk, else the current model if it clones, else
    /// the first downloaded cloning model. Returns a note for the user when no cloning model is downloaded.
    @discardableResult
    func cast(voiceID: UUID, preferredModel: ModelChoice? = nil) -> String? {
        let cloners = shelf.manifests(for: .tts, requiring: .cloning).filter(shelf.isAnyVariantDownloaded)
        var note: String?
        if let p = preferredModel, let m = cloners.first(where: { $0.id == p.modelID }) {
            if choice?.modelID != m.id { choice = ModelChoice(modelID: m.id, variantID: shelf.preferredVariant(m, requested: p.variantID).id) }
        } else if let m = manifest, m.capabilities.cloning, isDownloaded {
            // Keep the current model.
        } else if let m = cloners.first {
            choice = ModelChoice(modelID: m.id, variantID: shelf.preferredVariant(m).id)
        } else {
            note = "No model that clones is downloaded yet. Get Qwen3-TTS Base or Chatterbox Turbo in Models to perform with this voice."
        }
        voice = .library(voiceID)
        return note
    }
}
