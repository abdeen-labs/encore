import Foundation
import Testing
@testable import EncoreCore

@Test func paramValueRoundTrips() throws {
    let values: ParamValues = ["temperature": .double(0.7), "top_k": .int(50), "stream": .bool(false), "voice": .string("af_heart")]
    let decoded = try JSONDecoder().decode(ParamValues.self, from: JSONEncoder().encode(values))
    #expect(decoded == values)
}

@Test func bundledManifestsDecode() {
    let (_, problems) = ModelCatalog.bundled()
    #expect(problems.isEmpty, "\(problems)")
}
