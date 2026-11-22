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
}
