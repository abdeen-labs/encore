import Foundation

/// Which variant of a model family to recommend on this Mac.
///
/// Variants are ranked by quality — larger model first (when the family mixes sizes, e.g. Qwen3-TTS 1.7B and 0.6B),
/// then higher precision (fp32 > bf16 = fp16 > 8-bit > 6-bit > 5-bit > 4-bit), then larger memory estimate. The
/// recommendation is the best-ranked variant whose `memoryBytes` still leaves `headroomBytes` of installed RAM free;
/// when none does, it is the variant with the smallest memory estimate.
public enum VariantRecommendation {
    /// RAM that must stay free for the system and other apps once the model is loaded (4 GiB).
    public static let headroomBytes: Int64 = 4 << 30

    /// Installed RAM on this Mac.
    public static var installedMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// The recommended variant among `variants` for a Mac with `physicalMemory` bytes of RAM.
    public static func recommend(_ variants: [ModelVariant], physicalMemory: UInt64 = installedMemory) -> ModelVariant? {
        let ranked = rank(variants)
        let ram = Int64(clamping: physicalMemory)
        if let fit = ranked.first(where: { $0.memoryBytes <= ram - headroomBytes }) { return fit }
        return ranked.min { $0.memoryBytes < $1.memoryBytes }
    }

    /// `variants` best first (see the type's documentation). Stable for variants that compare equal.
    public static func rank(_ variants: [ModelVariant]) -> [ModelVariant] {
        variants.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            let (sx, sy) = (x.parameterBillions ?? 0, y.parameterBillions ?? 0)
            if sx != sy { return sx > sy }
            let (px, py) = (x.precisionBits ?? 16, y.precisionBits ?? 16)
            if px != py { return px > py }
            if x.memoryBytes != y.memoryBytes { return x.memoryBytes > y.memoryBytes }
            return a.offset < b.offset
        }.map(\.element)
    }
}

public extension ModelManifest {
    /// The variant to recommend on a Mac with `physicalMemory` bytes of RAM (default: this Mac).
    func recommendedVariant(physicalMemory: UInt64 = VariantRecommendation.installedMemory) -> ModelVariant {
        VariantRecommendation.recommend(variants, physicalMemory: physicalMemory) ?? variants[0]
    }
}

public extension ModelVariant {
    /// Weight precision in bits, read from the label or id ("bf16", "fp16", "fp32", "8-bit", "4bit", …);
    /// nil when neither names one (treated as full precision when ranking).
    var precisionBits: Int? {
        for text in [label, id] {
            let s = text.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if s.contains("fp32") || s.contains("f32") { return 32 }
            if s.contains("bf16") || s.contains("fp16") || s.contains("f16") { return 16 }
            if let m = s.firstMatch(of: #/(\d+)bit/#), let bits = Int(m.1) { return bits }
        }
        return nil
    }

    /// Model size in billions of parameters when the label or id names one ("1.7B", "0.6b", "3B"); nil otherwise.
    var parameterBillions: Double? {
        for text in [label, id] {
            let tokens = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == ".") }
            for t in tokens where t.hasSuffix("b") {
                if let n = Double(t.dropLast()), n > 0 { return n }
            }
        }
        return nil
    }
}
