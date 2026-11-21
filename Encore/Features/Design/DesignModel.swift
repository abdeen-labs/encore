import EncoreCore
import SwiftUI

/// Everything the Design screen does, without the views: the brief (description, sample line, model, language,
/// parameters, how many), auditions through `EncoreService.designVoice` (candidates arrive one by one), keeping one
/// as a library voice, discarding the rest, and hearing the kept voice. Kept for the app's lifetime.
@MainActor @Observable
final class DesignModel {
    /// A candidate clip from one run ("round"), and the library voice it became if kept.
    struct Audition: Identifiable, Equatable {
        var candidate: VoiceDesignCandidate
        var round: Int
        var number: Int
        var savedVoice: Voice?
        var id: UUID { candidate.id }
    }

    static let defaultSample = "Hello there. It's lovely to finally meet you — I've been looking forward to this conversation all week."

    static let examples: [(title: String, text: String)] = [
        ("Old sea captain", "A gruff, weathered old sea captain with a deep, gravelly voice, used to shouting over the wind, but warm underneath."),
        ("Late-night radio", "A calm, low-voiced late-night radio host, smooth and unhurried, with crisp diction and a hint of a smile."),
        ("Bright and quick", "A bright, quick-witted young woman, amused and a little breathless, speaking fast with lots of energy."),
        ("Bedtime story", "A gentle, soft-spoken grandmother telling a bedtime story, slow and tender, slightly husky."),
        ("Newsreader", "A precise, authoritative British newsreader, middle-aged man, measured pace, neutral and clear."),
    ]

    /// OmniVoice designs from attributes only (see `OmniVoiceAttributes`), so it gets examples in that form.
    static let attributeExamples: [(title: String, text: String)] = [
        ("Old sea captain", "male, elderly, very low pitch"),
        ("Late-night radio", "male, middle-aged, low pitch, american accent"),
        ("Bright and quick", "female, young adult, high pitch"),
        ("Bedtime story", "female, elderly, low pitch, whisper"),
        ("Newsreader", "male, middle-aged, moderate pitch, british accent"),
    ]

    /// The examples that suit the chosen model.
    var examples: [(title: String, text: String)] { manifest?.engine == "omnivoice" ? Self.attributeExamples : Self.examples }

    /// Why the description won't work with the chosen model, before anything runs (OmniVoice's attribute list).
    var descriptionProblem: String? {
        guard manifest?.engine == "omnivoice" else { return nil }
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? nil : OmniVoiceAttributes.problem(with: d)
    }

    let service: EncoreService
    let settings: AppSettings
    let shelf: ModelShelf
    let runner: JobRunner
    let tryout: VoiceTryout

    var description = ""
    var sampleText = DesignModel.defaultSample
    var choice: ModelChoice? { didSet { if choice?.modelID != oldValue?.modelID { modelChanged() } } }
    var language: String?
    /// Sparse: only values that differ from the model's defaults.
    var parameters: ParamValues = [:]
    var count = 3
    var showSettings = false

    private(set) var auditions: [Audition] = []
    private(set) var round = 0
    /// How many candidates the running round asked for.
    private(set) var roundSize = 0
    /// The audition being named for keeping.
    var keeping: UUID?
    var keepName = ""
    var keepTags: [String] = []
    private(set) var isSaving = false
    var saveError: String?
    /// The audition whose voice the "hear it" panel is showing.
    private(set) var tryoutFor: UUID?
    private(set) var isPrepared = false

    init(service: EncoreService, settings: AppSettings, shelf: ModelShelf) {
        self.service = service
        self.settings = settings
        self.shelf = shelf
        runner = JobRunner(runtime: service.runtime)
        tryout = VoiceTryout(service: service, shelf: shelf)
    }

    convenience init(deps: AppDependencies) {
        self.init(service: deps.service, settings: deps.settings, shelf: deps.modelShelf)
    }

    func prepare() async {
        await shelf.waitForScan()
        if choice == nil || !(manifest.map(shelf.isAnyVariantDownloaded) ?? false) {
            // The last designer used, else Qwen3-TTS VoiceDesign (made for prose descriptions), else what's on disk.
            let downloaded = designModels.filter(shelf.isAnyVariantDownloaded)
            if settings.lastUsedModels[.voiceDesign] == nil,
               let m = ["qwen3-tts-voicedesign", "voxcpm2", "omnivoice"].lazy.compactMap({ id in downloaded.first { $0.id == id } }).first {
                choice = ModelChoice(modelID: m.id, variantID: shelf.preferredVariant(m).id)
            } else if let c = shelf.initialChoice(for: .tts, requiring: .voiceDesign, feature: .voiceDesign, settings: settings) {
                choice = c
            } else if choice == nil, let m = designModels.first {
                choice = ModelChoice(modelID: m.id)
            }
        }
        isPrepared = true
    }

    // MARK: Derived

    var manifest: ModelManifest? { choice.flatMap { service.catalog.model($0.modelID) } }

    var designModels: [ModelManifest] { shelf.manifests(for: .tts, requiring: .voiceDesign) }

    var needsFirstModel: Bool { shelf.hasScanned && !shelf.hasDownloadedModel(for: .tts, requiring: .voiceDesign) }

    var isDownloaded: Bool { manifest.map { shelf.isDownloaded($0, variantID: choice?.variantID) } ?? false }

    /// Downloaded models that can perform a kept voice.
    var cloningModels: [ModelManifest] { tryout.cloningModels() }

    var blockedReason: String? {
        guard let m = manifest else { return "Choose a model that designs voices." }
        if shelf.hasScanned, !isDownloaded { return "Download the model first." }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe the voice first." }
        if descriptionProblem != nil { return "OmniVoice needs attributes, not a description." }
        if sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the auditions a line to say." }
        return nil
    }

    /// How this model wants the description, when it's particular.
    var descriptionHint: String? { manifest?.descriptionHelp }

    var pendingInRound: Int {
        guard runner.isRunning else { return 0 }
        return max(0, roundSize - auditions.filter { $0.round == round }.count)
    }

    var unsaved: [Audition] { auditions.filter { $0.savedVoice == nil } }

    // MARK: Actions

    /// Auditions `count` new voices for the description. Earlier auditions stay until discarded.
    func run() {
        guard blockedReason == nil, !runner.isBusy, let m = manifest, let choice else { return }
        var r = VoiceDesignRequest(modelID: m.id, description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                                   sampleText: sampleText.trimmingCharacters(in: .whitespacesAndNewlines))
        r.variantID = shelf.preferredVariant(m, requested: choice.variantID).id
        r.language = language
        r.parameters = ParameterValues.normalized(parameters, for: m)
        r.candidates = count
        let request = r
        let service = self.service
        let thisRound = round + 1
        runner.start(.voiceDesign, model: m, variantID: r.variantID) { [weak self] in
            self?.round = thisRound
            self?.roundSize = request.candidates
            return service.designVoice(request)
        } onEvent: { [weak self] event in
            guard let self, case .candidate(let c) = event else { return }
            let number = self.auditions.filter { $0.round == thisRound }.count + 1
            withStageAnimation(Theme.Motion.entrance) {
                self.auditions.insert(Audition(candidate: c, round: thisRound, number: number), at: self.insertionIndex(round: thisRound))
            }
        }
    }

    /// Newest round first; within a round, in order.
    private func insertionIndex(round: Int) -> Int {
        if let lastOfRound = auditions.lastIndex(where: { $0.round == round }) { return lastOfRound + 1 }
        return 0
    }

    /// "More like this": the same brief again.
    func moreLikeThis() { run() }

    func cancel() { runner.cancel() }

    func beginKeeping(_ id: UUID) {
        keeping = id
        saveError = nil
        if keepName.isEmpty || auditions.contains(where: { $0.savedVoice?.name == keepName }) { keepName = suggestedName }
    }

    var suggestedName: String {
        let words = description.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
        let skip: Set<String> = ["a", "an", "the", "with", "and", "of", "voice", "speaking", "who", "is", "very", "slightly", "little"]
        let picked = words.filter { !skip.contains($0.lowercased()) }.prefix(3)
        let base = picked.isEmpty ? "Designed voice" : picked.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let names = Set(service.voices.voices.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Saves the audition being kept as a library voice.
    func keep() async {
        guard let id = keeping, let i = auditions.firstIndex(where: { $0.id == id }) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let voice = try await service.saveDesignedVoice(auditions[i].candidate, name: keepName.isEmpty ? suggestedName : keepName,
                                                            tags: keepTags, language: VoiceLanguages.normalize(language))
            withStageAnimation(Theme.Motion.entrance) {
                auditions[i].savedVoice = voice
                keeping = nil
                tryoutFor = id
            }
            keepName = ""
            keepTags = []
            tryout.prepare(for: voice)
        } catch {
            saveError = ErrorPresentation(error)?.message ?? error.localizedDescription
        }
    }

    /// Deletes every audition that wasn't kept (kept ones stay listed).
    func discardUnsaved() {
        let drop = unsaved
        service.discardDesignCandidates(drop.map(\.candidate))
        withStageAnimation { auditions.removeAll { $0.savedVoice == nil } }
        if let k = keeping, !auditions.contains(where: { $0.id == k }) { keeping = nil }
    }

    func discard(_ id: UUID) {
        guard let a = auditions.first(where: { $0.id == id }), a.savedVoice == nil else { return }
        service.discardDesignCandidates([a.candidate])
        withStageAnimation { auditions.removeAll { $0.id == id } }
        if keeping == id { keeping = nil }
    }

    /// Clears the bench: unsaved clips are deleted, kept voices stay in the library.
    func clear() {
        discardUnsaved()
        withStageAnimation { auditions = []; tryoutFor = nil }
        tryout.reset()
    }

    private func modelChanged() {
        parameters = [:]
        if let l = language, let m = manifest, !m.languages.contains(where: { $0.code == l }) { language = nil }
    }

    #if DEBUG
    func debugSet(auditions: [Audition], round: Int, roundSize: Int = 0, keeping: UUID? = nil, tryoutFor: UUID? = nil) {
        self.auditions = auditions
        self.round = round
        self.roundSize = roundSize
        self.keeping = keeping
        self.tryoutFor = tryoutFor
    }
    #endif
}
