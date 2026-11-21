import EncoreCore
import Foundation
import MLXAudioCore

/// A job's parameter values layered over the manifest defaults. Keys are mlx-audio's Python kwarg names.
struct ResolvedParameters {
    let values: ParamValues

    init(manifest: ModelManifest, job: ParamValues) {
        values = manifest.defaultParameters.merging(job) { _, new in new }
    }

    func double(_ key: String) -> Double? { values[key]?.doubleValue }
    func float(_ key: String) -> Float? { double(key).map(Float.init) }
    func int(_ key: String) -> Int? { values[key]?.intValue }
    func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    func string(_ key: String) -> String? {
        guard let s = values[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// A seed, when the user fixed one. Negative or missing means "random".
    var seed: UInt64? {
        guard let v = values["seed"] else { return nil }
        if let i = v.intValue, i >= 0 { return UInt64(i) }
        if let s = v.stringValue, let u = UInt64(s) { return u }
        return nil
    }

    /// The sampling knobs shared by the autoregressive models, starting from the model's own defaults.
    func generateParameters(base: GenerateParameters) -> GenerateParameters {
        var p = base
        if let v = float("temperature") { p.temperature = v }
        if let v = float("top_p") { p.topP = v }
        if let v = int("top_k") { p.topK = v }
        if let v = float("min_p") { p.minP = v }
        if let v = float("repetition_penalty") { p.repetitionPenalty = v }
        if let v = int("max_tokens") { p.maxTokens = v }
        p.seed = seed
        return p
    }
}
