import Foundation
import Testing
@testable import EncoreCore

@Suite struct ManifestTests {
    let catalog = ModelCatalog.bundled()

    @Test func everyBundledManifestDecodes() {
        #expect(catalog.problems.isEmpty, "\(catalog.problems)")
        #expect(!catalog.catalog.models.isEmpty)
    }

    @Test func idsAreUnique() {
        let ids = catalog.catalog.models.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate manifest ids: \(ids)")
    }

    @Test(arguments: ModelCatalog.bundled().catalog.models)
    func manifestIsSane(_ m: ModelManifest) {
        #expect(!m.name.isEmpty && !m.summary.isEmpty && !m.engine.isEmpty, "\(m.id)")
        #expect(!m.tasks.isEmpty, "\(m.id) has no tasks")
        #expect(m.sampleRate > 0, "\(m.id) sample rate")

        // Variants
        #expect(!m.variants.isEmpty, "\(m.id) has no variants")
        #expect(Set(m.variants.map(\.id)).count == m.variants.count, "\(m.id) duplicate variant ids")
        #expect(m.variants.filter { $0.recommended == true }.count <= 1, "\(m.id) more than one recommended variant")
        for v in m.variants {
            #expect(v.repo.split(separator: "/").count == 2, "\(m.id)/\(v.id) repo \(v.repo)")
            #expect(v.downloadBytes > 0 && v.memoryBytes > 0, "\(m.id)/\(v.id) sizes")
            #expect(Set(v.allRepos).count == v.allRepos.count, "\(m.id)/\(v.id) repeats a repo")
        }

        // License
        #expect(!m.license.name.isEmpty, "\(m.id) license name")
        #expect(m.license.url?.hasPrefix("https://") == true, "\(m.id) license url")
        #expect(m.license.commercialUse != nil, "\(m.id) must say whether commercial use is allowed")
        #expect(!(m.license.summary ?? "").isEmpty, "\(m.id) license summary")
        #expect(m.license.gated != nil, "\(m.id) gated flag")

        // Parameters
        let keys = m.parameters.map(\.key)
        #expect(Set(keys).count == keys.count, "\(m.id) duplicate parameter keys: \(keys)")
        #expect(m.parameters.filter { $0.tier == .basic }.count <= 3, "\(m.id) basic tier should stay small")
        for p in m.parameters {
            #expect(!p.label.isEmpty && !(p.help ?? "").isEmpty, "\(m.id).\(p.key) needs a label and help")
            switch p.type {
            case .float, .int:
                guard let lo = p.min, let hi = p.max else {
                    Issue.record("\(m.id).\(p.key) needs min and max"); continue
                }
                #expect(lo < hi, "\(m.id).\(p.key) range")
                if let step = p.step { #expect(step > 0 && step <= hi - lo, "\(m.id).\(p.key) step") }
                if let d = p.defaultValue?.doubleValue {
                    #expect(d >= lo && d <= hi, "\(m.id).\(p.key) default \(d) outside \(lo)…\(hi)")
                } else {
                    Issue.record("\(m.id).\(p.key) numeric default missing")
                }
                if p.type == .int, let d = p.defaultValue { #expect(d.intValue != nil, "\(m.id).\(p.key) int default") }
            case .choice:
                let values = p.options?.map(\.value) ?? []
                #expect(!values.isEmpty, "\(m.id).\(p.key) has no options")
                #expect(Set(values).count == values.count, "\(m.id).\(p.key) duplicate options")
                if let d = p.defaultValue?.stringValue { #expect(values.contains(d), "\(m.id).\(p.key) default not an option") }
            case .bool:
                if let d = p.defaultValue { #expect(d.boolValue != nil, "\(m.id).\(p.key) bool default") }
            case .seed, .text:
                break
            }
        }

        // Voices, languages, tags, reference
        #expect(Set(m.presetVoices.map(\.id)).count == m.presetVoices.count, "\(m.id) duplicate voices")
        #expect(Set(m.languages.map(\.code)).count == m.languages.count, "\(m.id) duplicate languages")
        #expect(Set(m.expressiveTags.map(\.tag)).count == m.expressiveTags.count, "\(m.id) duplicate tags")
        #expect(m.capabilities.presetVoices == !m.presetVoices.isEmpty, "\(m.id) presetVoices flag vs list")
        #expect(m.capabilities.expressiveTags == !m.expressiveTags.isEmpty, "\(m.id) expressiveTags flag vs list")
        if m.tasks.contains(.tts) {
            #expect(m.maxChunkCharacters > 0, "\(m.id) maxChunkCharacters")
            #expect(m.capabilities.cloning == (m.reference != nil), "\(m.id) cloning needs a reference spec")
        }
        if let r = m.reference {
            #expect(r.minSeconds > 0 && r.minSeconds < r.maxSeconds, "\(m.id) reference range")
        }
    }
}
