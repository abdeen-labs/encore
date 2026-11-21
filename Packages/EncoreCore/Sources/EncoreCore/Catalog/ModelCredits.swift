import Foundation

/// Credit for one model family in the catalog: who made it and the licenses its weights come under.
public struct ModelCredit: Sendable, Hashable, Identifiable {
    public var family: String
    /// The family's authors, in manifest order (usually one organization).
    public var authors: [String]
    /// Every license name used across the family's models, sorted.
    public var licenses: [String]
    public var homepage: String?
    public var id: String { family }
}

public extension ModelCatalog {
    /// One credit per model family, sorted by family name. Built from the manifests, so adding or removing a
    /// manifest updates the credits.
    var credits: [ModelCredit] {
        var order: [String] = []
        var byFamily: [String: [ModelManifest]] = [:]
        for m in models {
            if byFamily[m.family] == nil { order.append(m.family) }
            byFamily[m.family, default: []].append(m)
        }
        return order.map { family in
            let ms = byFamily[family] ?? []
            var authors: [String] = []
            for a in ms.compactMap(\.author) where !authors.contains(a) { authors.append(a) }
            return ModelCredit(family: family, authors: authors, licenses: Array(Set(ms.map(\.license.name))).sorted(),
                               homepage: ms.compactMap(\.homepage).first)
        }
        .sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    /// The Hugging Face organizations whose repos Encore downloads weights from (e.g. the MLX conversions), sorted.
    var weightPublishers: [String] {
        let orgs = models.flatMap(\.variants).flatMap(\.allRepos).compactMap { $0.split(separator: "/").first.map(String.init) }
        return Array(Set(orgs)).sorted()
    }
}
