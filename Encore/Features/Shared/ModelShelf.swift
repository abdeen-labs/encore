import EncoreCore
import SwiftUI

// MARK: - Choice and requirements

/// The model (and variant) a screen has chosen. `variantID == nil` means the model's recommended variant.
struct ModelChoice: Hashable, Codable, Sendable {
    var modelID: String
    var variantID: String?

    init(modelID: String, variantID: String? = nil) {
        self.modelID = modelID
        self.variantID = variantID
    }
}

/// Capabilities a screen needs from its model. Pickers only list models that have all of them.
///
///     ModelPicker(task: .tts, requires: .cloning, selection: $choice)
struct ModelRequirement: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let cloning = ModelRequirement(rawValue: 1 << 0)
    static let voiceDesign = ModelRequirement(rawValue: 1 << 1)
    static let styleInstruction = ModelRequirement(rawValue: 1 << 2)
    static let presetVoices = ModelRequirement(rawValue: 1 << 3)
    static let expressiveTags = ModelRequirement(rawValue: 1 << 4)
    static let wordTimestamps = ModelRequirement(rawValue: 1 << 5)
    static let segmentTimestamps = ModelRequirement(rawValue: 1 << 6)
    static let nativeDialogue = ModelRequirement(rawValue: 1 << 7)

    func isSatisfied(by c: ModelCapabilities) -> Bool {
        (!contains(.cloning) || c.cloning) && (!contains(.voiceDesign) || c.voiceDesign)
            && (!contains(.styleInstruction) || c.styleInstruction) && (!contains(.presetVoices) || c.presetVoices)
            && (!contains(.expressiveTags) || c.expressiveTags) && (!contains(.wordTimestamps) || c.wordTimestamps)
            && (!contains(.segmentTimestamps) || c.segmentTimestamps) && (!contains(.nativeDialogue) || c.nativeDialogue)
    }

    /// What a backend must support on top of the task's basic feature.
    var engineFeatures: EngineFeatures {
        var f: EngineFeatures = []
        if contains(.cloning) { f.insert(.cloning) }
        if contains(.voiceDesign) { f.insert(.voiceDesign) }
        if contains(.wordTimestamps) { f.insert(.wordTimestamps) }
        return f
    }
}

/// Whether a model can run here, and on which runtime.
enum RuntimeVerdict: Equatable, Sendable {
    case runs(EngineRuntime)
    case blocked(ServiceError)
}

// MARK: - Shelf

/// What the pickers show about each model, cached for the whole app: downloaded or not (per variant),
/// which runtime it would run on, and whether it fits in memory. Refreshes itself when a download
/// finishes or a model is deleted. Get the app's one instance with `deps.modelShelf`.
@MainActor @Observable
final class ModelShelf {
    let service: EncoreService
    let downloads: ModelDownloadCenter

    /// Variants whose weights are on disk (as the service will accept them).
    private(set) var downloaded: Set<ModelVariantKey> = []
    /// True once the first scan of the cache has finished; before that nothing is known.
    private(set) var hasScanned = false
    private(set) var runtimes: [String: RuntimeVerdict] = [:]
    private(set) var assessments: [ModelVariantKey: MemoryAssessment] = [:]

    #if DEBUG
    /// Fixtures: runtimes to report without asking the backends (snapshots have none).
    var runtimeOverrides: [String: RuntimeVerdict] = [:]
    #endif

    @ObservationIgnored private var downloadedSignature: Set<ModelVariantKey> = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(service: EncoreService, downloads: ModelDownloadCenter) {
        self.service = service
        self.downloads = downloads
        rescan()
        observeDownloads()
        // Cheap (no backend is started to answer), so every picker shows its runtime before it opens.
        let models = service.catalog.models
        Task { [weak self] in await self?.refreshRuntimes(for: models) }
    }

    var catalog: ModelCatalog { service.catalog }

    // MARK: Queries

    /// Models for a task that have every required capability: downloaded ones first, then by name.
    func manifests(for task: ModelTask, requiring: ModelRequirement = []) -> [ModelManifest] {
        catalog.models(for: task)
            .filter { requiring.isSatisfied(by: $0.capabilities) }
            .sorted { a, b in
                let da = isAnyVariantDownloaded(a), db = isAnyVariantDownloaded(b)
                if da != db { return da }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    func isDownloaded(_ manifest: ModelManifest, variantID: String?) -> Bool {
        downloaded.contains(ModelVariantKey(manifest, manifest.variant(variantID)))
    }

    func isAnyVariantDownloaded(_ manifest: ModelManifest) -> Bool {
        manifest.variants.contains { downloaded.contains(ModelVariantKey(manifest, $0)) }
    }

    /// The best variant to use: the one asked for, else a downloaded one (recommended first), else the recommended one.
    func preferredVariant(_ manifest: ModelManifest, requested: String? = nil) -> ModelVariant {
        if let requested, let v = manifest.variants.first(where: { $0.id == requested }) { return v }
        if isDownloaded(manifest, variantID: manifest.defaultVariant.id) { return manifest.defaultVariant }
        return manifest.variants.first { downloaded.contains(ModelVariantKey(manifest, $0)) } ?? manifest.defaultVariant
    }

    func hasDownloadedModel(for task: ModelTask, requiring: ModelRequirement = []) -> Bool {
        manifests(for: task, requiring: requiring).contains(where: isAnyVariantDownloaded)
    }

    func runtime(for manifest: ModelManifest, requiring: ModelRequirement = []) -> RuntimeVerdict? {
        #if DEBUG
        if let o = runtimeOverrides[manifest.id] { return o }
        #endif
        return runtimes[Self.runtimeKey(manifest.id, requiring)]
    }

    func assessment(_ manifest: ModelManifest, variantID: String?) -> MemoryAssessment? {
        assessments[ModelVariantKey(manifest, manifest.variant(variantID))]
    }

    /// The model a feature should start on: the last one used for it (if it still qualifies), else the first
    /// downloaded one, else nil (nothing usable is downloaded).
    func initialChoice(for task: ModelTask, requiring: ModelRequirement = [], feature: AppSettings.Feature?,
                       settings: AppSettings) -> ModelChoice? {
        let candidates = manifests(for: task, requiring: requiring)
        if let feature, let last = settings.lastUsedModels[feature], let m = candidates.first(where: { $0.id == last }),
           isAnyVariantDownloaded(m) {
            return ModelChoice(modelID: m.id, variantID: preferredVariant(m).id)
        }
        guard let m = candidates.first(where: isAnyVariantDownloaded) else { return nil }
        return ModelChoice(modelID: m.id, variantID: preferredVariant(m).id)
    }

    // MARK: Refreshing

    /// Re-reads which variants are on disk (cheap; no network).
    func rescan() {
        scanTask?.cancel()
        let service = self.service
        let models = catalog.models
        scanTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> Set<ModelVariantKey> in
                var out = Set<ModelVariantKey>()
                for m in models { for v in m.variants where service.isDownloaded(m, variantID: v.id) { out.insert(ModelVariantKey(m, v)) } }
                return out
            }.value
            guard let self, !Task.isCancelled else { return }
            if self.downloaded != found { self.downloaded = found }
            self.hasScanned = true
        }
    }

    /// Waits for the scan in flight (tests, fixtures, the headless runner).
    func waitForScan() async { await scanTask?.value }

    /// Works out which runtime each model would use (`EncoreService.plannedRuntime`). Never starts the Python
    /// helper; runs at launch for every model's basic task, and again when a picker or the Models screen opens.
    func refreshRuntimes(for manifests: [ModelManifest], requiring: ModelRequirement = []) async {
        for m in manifests {
            let needs = requiring.engineFeatures.union(Self.basicNeeds(m))
            let verdict: RuntimeVerdict
            switch await service.plannedRuntime(modelID: m.id, needs: needs) {
            case .success(let r): verdict = .runs(r)
            case .failure(let e): verdict = .blocked(e)
            }
            let key = Self.runtimeKey(m.id, requiring)
            if runtimes[key] != verdict { runtimes[key] = verdict }
        }
    }

    /// Memory verdicts for every variant of these models.
    func refreshAssessments(for manifests: [ModelManifest]) async {
        for m in manifests {
            for v in m.variants {
                let a = await service.runtime.assess(m, v)
                let key = ModelVariantKey(m, v)
                if assessments[key] != a { assessments[key] = a }
            }
        }
    }

    // MARK: Private

    private static func runtimeKey(_ id: String, _ r: ModelRequirement) -> String { "\(id)|\(r.rawValue)" }

    private static func basicNeeds(_ m: ModelManifest) -> EngineFeatures {
        if m.tasks.contains(.tts) { return .synthesis }
        if m.tasks.contains(.stt) { return .transcription }
        return .voiceConversion
    }

    /// Rescans when a variant becomes downloaded or stops being downloaded (not on every progress tick).
    private func observeDownloads() {
        withObservationTracking { _ = downloads.states } onChange: { [weak self] in
            let owner = self
            Task { @MainActor in
                guard let self = owner else { return }
                let now = Set(self.downloads.states.filter { $0.value.isDownloaded }.map(\.key))
                if now != self.downloadedSignature {
                    self.downloadedSignature = now
                    self.rescan()
                }
                self.observeDownloads()
            }
        }
    }
}

// MARK: - Per-screen state

extension AppDependencies {
    /// A long-lived object for a screen, created on first use and kept for the app's lifetime, so a screen's
    /// state (script, selections, a running job) survives switching sections.
    ///
    ///     let model = deps.screenModel("Studio") { StudioModel(deps: deps) }
    func screenModel<T: AnyObject>(_ key: String, make: () -> T) -> T {
        if let existing = screenModels[key] as? T { return existing }
        let made = make()
        screenModels[key] = made
        return made
    }

    /// The app's model availability cache, shared by every picker.
    var modelShelf: ModelShelf {
        screenModel("Shared.ModelShelf") { ModelShelf(service: service, downloads: downloads) }
    }
}
