import Foundation
import Testing
@testable import EncoreCore

@MainActor @Suite struct OmniVoiceAttributeTests {
    @Test func attributeListsPassAndProseIsRefused() {
        #expect(OmniVoiceAttributes.problem(with: "female, young adult, low pitch, british accent") == nil)
        #expect(OmniVoiceAttributes.problem(with: "Male，Elderly , WHISPER") == nil)
        #expect(OmniVoiceAttributes.problem(with: "female, young adult, 四川话") == nil)
        let prose = "A calm, low-voiced late-night radio host, smooth and unhurried"
        #expect(OmniVoiceAttributes.unknownItems(in: prose) == ["a calm", "low-voiced late-night radio host", "smooth and unhurried"])
        #expect(OmniVoiceAttributes.problem(with: prose)?.contains("not a description") == true)
        #expect(OmniVoiceAttributes.problem(with: "female, deep voice") != nil)
    }

    @Test func designRefusesProseForOmniVoiceBeforeLoading() async throws {
        let m = testManifest("omni", engine: "omnivoice", capabilities: ["voiceDesign": true])
        let backend = FakeBackend(.mlxSwift, features: ["omnivoice": [.synthesis, .voiceDesign]])
        let w = try ServiceWorld(models: [m], backends: [backend])
        let r = VoiceDesignRequest(modelID: "omni", description: "A calm, low-voiced late-night radio host", sampleText: "Hello.")
        await #expect(throws: ServiceError.self) { _ = try await collect(w.service.designVoice(r)) }
        #expect(backend.synthCalls.isEmpty)
    }

    @Test func soundTagsAreCutOutOfTheText() {
        let text = "<|text_start|>a brief update. [sigh]\nThe fan [laughter].[Sigh] [sniff]<|text_end|>"
        let segments = OmniVoiceTags.segments(text).map(String.init)
        #expect(segments == ["<|text_start|>a brief update. ", "[sigh]", "\nThe fan ", "[laughter]",
                             ".[Sigh] [sniff]<|text_end|>"])
        #expect(segments.joined() == text)
        #expect(OmniVoiceTags.segments("[sigh][laughter]").map(String.init) == ["[sigh]", "[laughter]"])
        #expect(OmniVoiceTags.segments("No tags here.").map(String.init) == ["No tags here."])
        #expect(OmniVoiceTags.segments("").isEmpty)
    }

    @Test func everyOmniVoiceManifestTagIsCutOut() throws {
        let manifest = try #require(ModelCatalog.bundled().catalog.models.first { $0.engine == "omnivoice" })
        for tag in manifest.expressiveTags.map(\.tag) {
            #expect(OmniVoiceTags.all.contains(tag), "\(tag) would be tokenized with the words around it")
        }
    }
}
