import EncoreCore
import Foundation

func runCatalogCommand(_ args: [String]) async throws {
    let (catalog, problems) = ModelCatalog.bundled()
    for model in catalog.models {
        let tasks = model.tasks.map(\.rawValue).joined(separator: ",")
        print("\(model.id)\t\(tasks)\t\(model.engine)\t\(model.license.name)\t\(model.variants.map(\.repo).joined(separator: " "))")
    }
    for problem in problems { print("PROBLEM \(problem)") }
    if !problems.isEmpty { exit(1) }
}
