import AppKit
import EncoreCore
import GRDB
import SwiftUI

/// Everything the Studio screen does, without the views: the script and its plan, the cast (model, voice,
/// language, direction), the settings, performing through the service, and the takes (speech history).
/// One instance lives for the app's lifetime (`deps.screenModel("Studio")`), so switching sections keeps the
/// script and a running job; the draft also survives relaunch when `drafts` is given.
@MainActor @Observable
final class StudioModel {
    enum WingsTab: String, CaseIterable, Hashable { case takes = "Takes", tuning = "Tuning" }

    let service: EncoreService
    let settings: AppSettings
    let voices: VoiceLibrary
    let pronunciations: PronunciationStore
    let shelf: ModelShelf
    let runner: JobRunner
    @ObservationIgnored let editor = ScriptEditorController()
    @ObservationIgnored private let drafts: UserDefaults?

    // MARK: State

    var choice: ModelChoice? {
        didSet { if choice?.modelID != oldValue?.modelID { modelChanged(from: oldValue) }; saveDraft() }
    }
    var voice: VoiceSelection = .automatic { didSet { saveDraft() } }
    /// nil = the model's default / automatic.
    var language: String? { didSet { saveDraft() } }
    /// Style direction or voice description, for models that take one.
    var instruct = "" { didSet { saveDraft() } }
    var script = "" { didSet { saveDraft() } }
    /// Sparse: only values that differ from the model's defaults.
    var parameters: ParamValues = [:] { didSet { saveDraft() } }
    var post: PostProcessingOptions { didSet { saveDraft() } }
    var autoChunk = true { didSet { saveDraft() } }

    var showAdvanced = false
    var wingsTab: WingsTab = .tuning
    var showPronunciations = false

    /// Recent speech takes, newest first (history records, so they survive relaunch).
    private(set) var takes: [HistoryItem] = []
    private(set) var takesTotal = 0
    /// Takes made since launch.
    private(set) var sessionTakeIDs: Set<UUID> = []
    /// True once the shelf has been scanned and a starting model picked.
    private(set) var isPrepared = false
    /// The restored draft named a model that is no longer in the catalog; the screen says so until dismissed.
    var draftModelRetired = false

    @ObservationIgnored private var perModel: [String: PerModel] = [:]
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var takesTask: Task<Void, Never>?
    @ObservationIgnored private var planCache: (key: Int, plan: ScriptPlan)?

    private struct PerModel { var voice: VoiceSelection; var language: String?; var parameters: ParamValues; var instruct: String }

    static let takesLimit = 40

    init(service: EncoreService, settings: AppSettings, voices: VoiceLibrary, pronunciations: PronunciationStore,
         shelf: ModelShelf, drafts: UserDefaults?) {
        self.service = service
        self.settings = settings
        self.voices = voices
        self.pronunciations = pronunciations
        self.shelf = shelf
        self.drafts = drafts
        self.runner = JobRunner(runtime: service.runtime)
        self.post = settings.postProcessing
        restoreDraft()
        observeTakes()
    }

    convenience init(deps: AppDependencies) {
        self.init(service: deps.service, settings: deps.settings, voices: deps.voices, pronunciations: deps.pronunciations,
                  shelf: deps.modelShelf, drafts: deps.drafts)
    }

    isolated deinit { takesTask?.cancel() }

    /// Picks a starting model once the cache has been scanned (keeps a restored draft's choice if it still exists).
    func prepare() async {
        await shelf.waitForScan()
        let retired = choice.map { service.catalog.model($0.modelID)?.tasks.contains(.tts) != true } ?? false
        if retired { setChoiceQuietly(nil) }
        if choice == nil, let initial = shelf.initialChoice(for: .tts, feature: .speech, settings: settings) {
            setChoiceQuietly(initial)
        }
        if retired {
            // The draft's voice, language and parameters belonged to the model that left; keep only what carries over.
            draftModelRetired = true
            let m = manifest
            if case .library = voice, m?.capabilities.cloning == true {} else { voice = .automatic }
            if let l = language, m?.languages.contains(where: { $0.code == l }) != true { language = nil }
            parameters = [:]
            if directionKind == nil { instruct = "" }
        }
        if !takes.isEmpty, script.isEmpty { wingsTab = .takes }
        isPrepared = true
    }

    // MARK: Derived

    var manifest: ModelManifest? { choice.flatMap { service.catalog.model($0.modelID) } }

    var isDownloaded: Bool {
        guard let m = manifest else { return false }
        return shelf.isDownloaded(m, variantID: choice?.variantID)
    }

    /// No speech model is on disk at all: the screen should lead to Models.
    var needsFirstModel: Bool { shelf.hasScanned && !shelf.hasDownloadedModel(for: .tts) }

    /// The model takes a style direction or a description.
    var directionKind: DirectionKind? {
        guard let c = manifest?.capabilities else { return nil }
        if c.styleInstruction { return .style }
        if c.voiceDesign { return .description }
        return nil
    }

    enum DirectionKind { case style, description }

    /// The script as the service will perform it, for highlighting, stats and issues. Cached per input.
    var plan: ScriptPlan? {
        guard let m = manifest else { return nil }
        let library = voices.voices
        let entries = pronunciations.entries.filter(\.enabled)
        var h = Hasher()
        h.combine(script); h.combine(m.id); h.combine(autoChunk)
        for v in library { h.combine(v.id); h.combine(v.name) }
        for e in entries { h.combine(e) }
        let key = h.finalize()
        if let planCache, planCache.key == key { return planCache.plan }
        var request = SpeechRequest(modelID: m.id, text: script)
        request.autoChunk = autoChunk
        let plan = ScriptPlanner(request: request, manifest: m, library: library, pronunciations: entries).plan(script)
        planCache = (key, plan)
        return plan
    }

    /// Why Perform can't run right now, or nil.
    var blockedReason: String? {
        guard let m = manifest else { return "Choose a model to perform with." }
        if shelf.hasScanned, !isDownloaded { return "\(m.name) isn't downloaded yet." }
        if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write something to perform." }
        if let plan {
            if let name = plan.parsed.unknownVoiceNames.first { return "No voice called “\(name)”: fix the [voice:] tag." }
            if let e = plan.issues.first(where: { $0.severity == .error }) { return e.message }
            if plan.chunks.isEmpty { return "There's nothing to say between the tags." }
        }
        if case .library = voice, !m.capabilities.cloning { return "\(m.name) can't speak in library voices. Pick one of its own." }
        return nil
    }

    var idleNote: String? {
        guard let m = manifest, let plan, !plan.chunks.isEmpty else { return nil }
        let v = VoiceDescription(voice, manifest: m, library: voices).name
        let chunks = plan.chunks.count == 1 ? "1 chunk" : "\(plan.chunks.count) chunks"
        return "\(chunks) · \(v) · \(m.name)"
    }

    // MARK: Actions

    func perform() {
        guard blockedReason == nil, !runner.isBusy, let m = manifest, let choice else { return }
        var r = SpeechRequest(modelID: m.id, text: script)
        r.variantID = shelf.preferredVariant(m, requested: choice.variantID).id
        r.voice = voice
        let direction = instruct.trimmingCharacters(in: .whitespacesAndNewlines)
        if directionKind != nil, !direction.isEmpty { r.instruct = direction }
        r.language = language
        r.parameters = ParameterValues.normalized(parameters, for: m)
        r.post = post
        r.autoChunk = autoChunk
        let service = self.service
        let request = r
        runner.start(.speech, model: m, variantID: r.variantID) {
            service.speak(request)
        } onEvent: { [weak self] event in
            guard let self, case .finished(let record) = event else { return }
            self.sessionTakeIDs.insert(record.id)
            withStageAnimation { self.wingsTab = .takes }
        }
    }

    func cancel() { runner.cancel() }

    /// Loads a take's model and variant, voice, language, direction, parameters, finishing and script back into the desk.
    func reuse(_ record: GenerationRecord) -> String? {
        guard let m = service.catalog.model(record.modelID), m.tasks.contains(.tts) else {
            return "That take's model isn't in this version of Encore."
        }
        let variant = record.variantID.flatMap { id in m.variants.first { $0.id == id }?.id }
        restoring = true
        choice = ModelChoice(modelID: m.id, variantID: shelf.preferredVariant(m, requested: variant ?? (choice?.modelID == m.id ? choice?.variantID : nil)).id)
        restoring = false
        parameters = ParameterValues.normalized(record.parameters, for: m)
        language = record.language.flatMap { l in m.languages.contains { $0.code == l } ? l : nil }
        instruct = record.instruct ?? ""
        if let p = record.post { post = p }
        if let id = record.voiceID, voices.voice(id) != nil {
            voice = .library(id)
        } else if let name = record.voiceName, let p = m.presetVoices.first(where: { $0.name == name || $0.id == name }) {
            voice = .preset(p.id)
        } else {
            voice = .automatic
        }
        script = record.text
        return nil
    }

    func toggleFavorite(_ item: HistoryItem) {
        Task { try? await service.history.setFavorite(!item.favorite, for: item.id) }
    }

    func delete(_ item: HistoryItem) {
        Task { try? await service.history.delete(item.id) }
    }

    func copyScript(_ record: GenerationRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
    }

    // MARK: Model changes

    private func setChoiceQuietly(_ c: ModelChoice?) {
        restoring = true
        choice = c
        restoring = false
    }

    /// Keeps each model's cast and settings for this session, and gives a newly picked model its own
    /// (or its defaults): a library voice carries over to another cloning model, nothing else does.
    private func modelChanged(from old: ModelChoice?) {
        guard !restoring else { return }
        draftModelRetired = false
        if let old {
            perModel[old.modelID] = PerModel(voice: voice, language: language, parameters: parameters, instruct: instruct)
        }
        guard let m = manifest else { return }
        if let saved = perModel[m.id] {
            voice = saved.voice; language = saved.language; parameters = saved.parameters; instruct = saved.instruct
        } else {
            if case .library = voice, m.capabilities.cloning {} else { voice = .automatic }
            if let l = language, !m.languages.contains(where: { $0.code == l }) { language = nil }
            parameters = [:]
            if directionKind == nil { instruct = "" }
        }
    }

    // MARK: Takes

    private func observeTakes() {
        let observation = service.history.observe(HistoryQuery(kinds: [.speech]), limit: Self.takesLimit)
        takesTask = Task { [weak self] in
            do {
                for try await page in observation {
                    guard let self else { return }
                    withStageAnimation(Theme.Motion.entrance) {
                        self.takes = page.items
                        self.takesTotal = page.total
                    }
                }
            } catch {}
        }
    }

    // MARK: Draft

    private struct Draft: Codable {
        var choice: ModelChoice?
        var voice: VoiceSelection
        var language: String?
        var instruct: String
        var script: String
        var parameters: ParamValues
        var post: PostProcessingOptions
        var autoChunk: Bool
    }

    private static let draftKey = "Studio.draft"

    private func saveDraft() {
        guard let drafts, !restoring else { return }
        let d = Draft(choice: choice, voice: voice, language: language, instruct: instruct, script: script,
                      parameters: parameters, post: post, autoChunk: autoChunk)
        if let data = try? JSONEncoder().encode(d) { drafts.set(data, forKey: Self.draftKey) }
    }

    private func restoreDraft() {
        guard let drafts, let data = drafts.data(forKey: Self.draftKey),
              let d = try? JSONDecoder().decode(Draft.self, from: data) else { return }
        restoring = true
        choice = d.choice; voice = d.voice; language = d.language; instruct = d.instruct; script = d.script
        parameters = d.parameters; post = d.post; autoChunk = d.autoChunk
        restoring = false
    }

    #if DEBUG
    /// Fixtures and the headless runner: set state without the per-model bookkeeping.
    func debugSet(choice: ModelChoice?, voice: VoiceSelection = .automatic, script: String, parameters: ParamValues = [:],
                  instruct: String = "", language: String? = nil) {
        restoring = true
        self.choice = choice
        restoring = false
        self.voice = voice
        self.script = script
        self.parameters = parameters
        self.instruct = instruct
        self.language = language
    }

    func debugMarkSessionTake(_ id: UUID) { sessionTakeIDs.insert(id) }
    #endif
}
