import EncoreCore
import Foundation

extension ModelVariant {
    /// "Large · Full quality", "Balanced", "Compact"… for people; falls back to `label` when it can't be read.
    ///
    ///     variant.friendlyName(in: manifest)   // "1.7B · 8-bit" → "Balanced" (one size) or "Large · Balanced"
    func friendlyName(in manifest: ModelManifest) -> String {
        VariantNaming.friendlyName(label, siblings: manifest.variants.map(\.label))
    }
}

/// Reads catalog variant labels (`bf16`, `0.6B · 8-bit`, `1.1 · bf16`) as a size and a precision.
enum VariantNaming {
    struct Parts: Equatable {
        /// Billions of parameters ("1.7B" → 1.7), when the label names a size.
        var size: Double?
        /// The precision in plain words ("Full quality", "Balanced", "Small", "Compact").
        var precision: String?
    }

    /// `label` as people read it, given the labels of every variant of the same model (sizes are only
    /// named when the model comes in more than one).
    static func friendlyName(_ label: String, siblings: [String]) -> String {
        guard let parts = parse(label) else { return label }
        let sizes = Set(siblings.compactMap { parse($0)?.size }).sorted()
        var words: [String] = []
        if let size = parts.size, sizes.count > 1 {
            words.append(size == sizes.last ? "Large" : (size == sizes.first ? "Small" : "Medium"))
        }
        if let precision = parts.precision { words.append(precision) }
        return words.isEmpty ? label : words.joined(separator: " · ")
    }

    /// Nil when any part of the label isn't a size, a precision or a bare version number.
    static func parse(_ label: String) -> Parts? {
        var parts = Parts()
        for piece in label.split(separator: "·") {
            let p = piece.trimmingCharacters(in: .whitespaces).lowercased()
            if let precision = precisionName(p) {
                parts.precision = precision
            } else if p.hasSuffix("b"), let n = Double(p.dropLast()) {
                parts.size = n
            } else if Double(p) != nil || (p.hasPrefix("v") && Double(p.dropFirst()) != nil) {
                continue  // a version ("1.1", "v2"): no size meaning
            } else {
                return nil
            }
        }
        return parts.size == nil && parts.precision == nil ? nil : parts
    }

    static func precisionName(_ p: String) -> String? {
        switch p {
        case "bf16", "fp16", "fp32", "f16", "f32": "Full quality"
        case "8-bit", "8bit", "int8": "Balanced"
        case "6-bit", "6bit", "5-bit", "5bit": "Small"
        case "4-bit", "4bit", "int4": "Compact"
        default: nil
        }
    }
}
