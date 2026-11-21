import Foundation
import Testing
@testable import EncoreCore

@Suite struct VariantRecommendationTests {
    let catalog = ModelCatalog.bundled().catalog
    static let gb: UInt64 = 1 << 30

    private func recommended(_ id: String, ram gigabytes: UInt64) -> String? {
        catalog.model(id)?.recommendedVariant(physicalMemory: gigabytes * Self.gb).id
    }

    @Test func parsesPrecisionAndSize() throws {
        let qwen = try #require(catalog.model("qwen3-tts-base"))
        let small = try #require(qwen.variants.first { $0.id == "0.6b-8bit" })
        #expect(small.precisionBits == 8 && small.parameterBillions == 0.6)
        #expect(qwen.variants.first { $0.id == "1.7b-bf16" }?.precisionBits == 16)
        #expect(catalog.model("chatterbox-turbo")?.variants.first { $0.id == "4bit" }?.parameterBillions == nil)
        #expect(catalog.model("soprano")?.variants[0].parameterBillions == nil, "a version number is not a size")
        #expect(catalog.model("orpheus")?.variants[0].parameterBillions == 3)
        #expect(VariantRecommendation.rank(qwen.variants).map(\.id)
                == ["1.7b-bf16", "1.7b-8bit", "1.7b-4bit", "0.6b-bf16", "0.6b-8bit", "0.6b-4bit"])
    }

    /// Expected variant ids on Macs with 8, 16, 24, 48 and 128 GB of RAM, against the bundled manifests.
    @Test(arguments: [
        ("qwen3-tts-base", ["0.6b-4bit", "1.7b-bf16", "1.7b-bf16", "1.7b-bf16", "1.7b-bf16"]),
        ("voxcpm2", ["4bit", "bf16", "bf16", "bf16", "bf16"]),
        ("chatterbox-turbo", ["8bit", "fp16", "fp16", "fp16", "fp16"]),
        ("omnivoice", ["8bit", "bf16", "bf16", "bf16", "bf16"]),
        ("orpheus", ["4bit", "8bit", "8bit", "8bit", "8bit"]),
        ("whisper-large-v3", ["fp16", "fp16", "fp16", "fp16", "fp16"]),
        ("soprano", ["bf16", "bf16", "bf16", "bf16", "bf16"]),
    ])
    func recommendationByRAM(_ id: String, expected: [String]) {
        let got = [8, 16, 24, 48, 128].map { recommended(id, ram: UInt64($0)) }
        #expect(got == expected, "\(id)")
    }

    @Test func fallsBackThroughSmallerVariants() {
        // 13 GB: 1.7B bf16 (10.4 GB) and 8-bit (8.9 GB) would leave under 4 GiB free; 1.7B 4-bit (8.0 GB) fits.
        #expect(catalog.model("qwen3-tts-base")?.recommendedVariant(physicalMemory: 13_000_000_000).id == "1.7b-4bit")
        // Nothing leaves 4 GiB free: the smallest memory estimate wins.
        #expect(recommended("voxcpm2", ram: 2) == "4bit")
    }

    @Test func everythingNamingTheRecommendedVariantAgrees() throws {
        let m = try #require(catalog.model("qwen3-tts-base"))
        #expect(m.defaultVariant == m.recommendedVariant())
        #expect(m.variant(nil) == m.recommendedVariant())
        #expect(m.variant("no-such-variant") == m.recommendedVariant())
    }
}
