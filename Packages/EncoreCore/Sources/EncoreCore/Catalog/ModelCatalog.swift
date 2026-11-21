import Foundation

/// The bundled model manifests.
public struct ModelCatalog: Sendable {
    public let models: [ModelManifest]

    public init(models: [ModelManifest]) { self.models = models }

    /// Loads every `*.json` under `Resources/Manifests`. A manifest that fails to decode is
    /// reported in `problems` rather than silently dropped.
    public static func bundled() -> (catalog: ModelCatalog, problems: [String]) {
        var models: [ModelManifest] = []
        var problems: [String] = []
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Manifests") ?? []
        let decoder = JSONDecoder()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do { models.append(try decoder.decode(ModelManifest.self, from: Data(contentsOf: url))) }
            catch { problems.append("\(url.lastPathComponent): \(error)") }
        }
        return (ModelCatalog(models: models), problems)
    }

    public func model(_ id: String) -> ModelManifest? { models.first { $0.id == id } }
    public func models(for task: ModelTask) -> [ModelManifest] { models.filter { $0.tasks.contains(task) } }
}
