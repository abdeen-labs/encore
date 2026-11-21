import EncoreCore
import GRDB
import SwiftUI

/// Everything the Changer does, without the views: the source recording and how it will be cut, the target voice
/// and model, the settings, converting through the service, and the result with its before/after comparison.
/// One instance lives for the app's lifetime (`deps.screenModel("Changer")`); the setup also survives relaunch.
@MainActor @Observable
final class ChangerModel {
    enum Side: String, CaseIterable, Hashable { case original = "Original", converted = "Converted" }

    let service: EncoreService
    let settings: AppSettings
    let voices: VoiceLibrary
    let shelf: ModelShelf
    let runner: JobRunner
    @ObservationIgnored private let drafts: UserDefaults?

    // MARK: State

    var choice: ModelChoice? { didSet { if choice?.modelID != oldValue?.modelID, !restoring { parameters = [:] }; saveDraft() } }
    private(set) var source: Source?
    var voiceID: UUID? { didSet { saveDraft() } }
    /// Sparse: only values that differ from the model's defaults.
    var parameters: ParamValues = [:] { didSet { saveDraft() } }
    var post: PostProcessingOptions { didSet { saveDraft() } }
    /// Longest piece the recording is cut into (at pauses) before converting.
    var pieceSeconds: Double = 20 { didSet { if pieceSeconds != oldValue { saveDraft(); resegment() } } }
    var showTuning = false
    var voiceQuery = ""

    /// The latest conversion (this session or restored), and the side of the comparison that's playing.
    private(set) var result: Result?
    var side: Side = .converted
    /// Earlier conversions, newest first.
    private(set) var recent: [HistoryItem] = []
    private(set) var recentTotal = 0
    /// The Python helper's whereabouts (the voice changer only runs there). nil until checked.
    private(set) var python: PythonRuntime.Lookup?
    private(set) var isPrepared = false

    struct Source: Equatable {
        var url: URL
        var info: MediaInfo?
        var track: PlaybackTrack
        /// How the service will cut it (same segmenter, same options), nil while measuring.
        var pieces: [AudioSegment]?
        var problem: String?
        static func == (a: Source, b: Source) -> Bool { a.url == b.url && a.info == b.info && a.pieces == b.pieces && a.problem == b.problem }
    }

    struct Result {
        var record: GenerationRecord
        var track: PlaybackTrack
        /// The recording it was made from, when it's still where it was.
        var original: PlaybackTrack?
    }

    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var recentTask: Task<Void, Never>?
    @ObservationIgnored private var segmentTask: Task<Void, Never>?

    init(service: EncoreService, settings: AppSettings, voices: VoiceLibrary, shelf: ModelShelf, drafts: UserDefaults?) {
        self.service = service
        self.settings = settings
        self.voices = voices
        self.shelf = shelf
        self.drafts = drafts
        self.runner = JobRunner(runtime: service.runtime)
        self.post = settings.postProcessing
        restoreDraft()
        observeRecent()
    }

    convenience init(deps: AppDependencies) {
        self.init(service: deps.service, settings: deps.settings, voices: deps.voices, shelf: deps.modelShelf,
                  drafts: deps.drafts)
    }

    isolated deinit { recentTask?.cancel(); segmentTask?.cancel() }

    func prepare() async {
        await shelf.waitForScan()
        if let c = choice, service.catalog.model(c.modelID)?.tasks.contains(.voiceConversion) != true { setChoiceQuietly(nil) }
        if choice == nil, let initial = shelf.initialChoice(for: .voiceConversion, feature: .voiceChange, settings: settings) {
            setChoiceQuietly(initial)
        }
        if choice == nil, let any = shelf.manifests(for: .voiceConversion).first {
            setChoiceQuietly(ModelChoice(modelID: any.id, variantID: shelf.preferredVariant(any).id))
        }
        if let id = voiceID, voices.voice(id) == nil { voiceID = nil }
        #if DEBUG
        if pythonOverride == nil { python = PythonRuntime.locate() }
        #else
        python = PythonRuntime.locate()
        #endif
        isPrepared = true
    }

    // MARK: Derived

    var manifest: ModelManifest? { choice.flatMap { service.catalog.model($0.modelID) } }

    var isDownloaded: Bool {
        guard let m = manifest else { return false }
        return shelf.isDownloaded(m, variantID: choice?.variantID)
    }

    /// No voice-changer model on disk: lead to Models.
    var needsFirstModel: Bool { shelf.hasScanned && !shelf.hasDownloadedModel(for: .voiceConversion) }

    var voice: Voice? { voiceID.flatMap { voices.voice($0) } }

    var hasVoices: Bool { !voices.voices.isEmpty }

    /// The library, filtered by the search field.
    var filteredVoices: [Voice] { voices.search(voiceQuery) }

    /// Why the helper can't run the model, when it can't (nil when fine or not yet known).
    var helperProblem: String? {
        guard let m = manifest else { return nil }
        if case .blocked(let e)? = shelf.runtime(for: m) {
            switch e {
            case .backendNeedsSetup(_, let message), .backendUnavailable(_, let message): return message
            default: break
            }
        }
        guard Self.runsOnlyInPython(m) else { return nil }
        switch python {
        case .needsSetup(let message)?, .missing(let message)?: return message
        default: return nil
        }
    }

    /// The voice changer has no native port (see the model's summary); other conversion models may.
    static func runsOnlyInPython(_ m: ModelManifest) -> Bool { m.engine == "chatterbox_vc" }

    var blockedReason: String? {
        guard let m = manifest else { return "Choose a voice-changer model." }
        if shelf.hasScanned, !isDownloaded { return "\(m.name) isn't downloaded yet." }
        guard let source else { return "Add the recording to re-voice." }
        if let p = source.problem { return p }
        guard voiceID != nil else { return hasVoices ? "Choose the voice it should be in." : "Make a voice first: clone or design one." }
        if voice == nil { return "That voice was deleted. Choose another." }
        if helperProblem != nil { return "\(m.name) needs the Python helper set up." }
        return nil
    }

    var idleNote: String? {
        guard let source, let voice, let m = manifest else { return nil }
        let pieces = source.pieces.map { $0.count == 1 ? "1 piece" : "\($0.count) pieces" } ?? "measuring"
        return "\(Timecode.string(source.info?.duration ?? 0, tenths: false)) · \(pieces) · \(voice.name) · \(m.name)"
    }

    /// The piece being converted right now (0-based), from the service's "Converting 3 of 7" stage.
    var activePiece: Int? {
        guard runner.isRunning, let stage = runner.stage else { return nil }
        if stage == "Converting" { return 0 }
        guard stage.hasPrefix("Converting ") else {
            // Past the last piece (stitching, post-processing, saving): everything is done.
            if let n = source?.pieces?.count, stage.hasPrefix("Normal") || stage.hasPrefix("Saving") || stage.hasPrefix("Tighten") { return n }
            return nil
        }
        let parts = stage.dropFirst("Converting ".count).split(separator: " ")
        guard let first = parts.first, let n = Int(first) else { return nil }
        return n - 1
    }

    // MARK: Source

    func setSource(_ url: URL) {
        let track = PlaybackTrack(url: url, title: url.deletingPathExtension().lastPathComponent)
        source = Source(url: url, info: nil, track: track, pieces: nil)
        saveDraft()
        measure(url)
    }

    func clearSource() {
        source?.track.pause()
        source = nil
        segmentTask?.cancel()
        saveDraft()
    }

    private func measure(_ url: URL) {
        segmentTask?.cancel()
        let seconds = pieceSeconds
        segmentTask = Task { [weak self] in
            var info: MediaInfo?
            var problem: String?
            do { info = try await AudioReader.probe(url) } catch { problem = "Couldn't read \(url.lastPathComponent): \(ErrorPresentation.clip(error.localizedDescription))" }
            guard let self, !Task.isCancelled, self.source?.url == url else { return }
            self.source?.info = info
            self.source?.problem = problem
            if let info, info.duration < 0.3 { self.source?.problem = "That recording is too short to convert." }
            guard problem == nil else { return }
            let pieces = try? await SpeechSegmenter.segment(fileAt: url, options: Self.segmentOptions(seconds))
            guard !Task.isCancelled, self.source?.url == url else { return }
            self.source?.pieces = pieces ?? [AudioSegment(index: 0, start: 0, end: info?.duration ?? 0)]
        }
    }

    private func resegment() {
        guard let url = source?.url else { return }
        source?.pieces = nil
        measure(url)
    }

    /// The same cut the service makes (`EncoreService.conversionSegmentOptions`).
    static func segmentOptions(_ seconds: Double) -> SpeechSegmenter.Options {
        SpeechSegmenter.Options(maxDuration: max(4, seconds), minDuration: min(4, seconds / 2))
    }

    // MARK: Actions

    func convert() {
        guard blockedReason == nil, !runner.isBusy, let m = manifest, let choice, let source, let voiceID else { return }
        var r = VoiceConversionRequest(modelID: m.id, sourcePath: source.url.path, voice: .library(voiceID))
        r.variantID = shelf.preferredVariant(m, requested: choice.variantID).id
        var params = ParameterValues.normalized(parameters, for: m)
        if pieceSeconds != 20 { params["segment_seconds"] = .double(pieceSeconds) }
        r.parameters = params
        r.post = post
        source.track.pause()
        let service = self.service
        let request = r
        let original = source.url
        runner.start(.voiceConversion, model: m, variantID: r.variantID) {
            service.convertVoice(request)
        } onEvent: { [weak self] event in
            guard let self, case .finished(let record) = event else { return }
            withStageAnimation(Theme.Motion.entrance) { self.show(record, original: original) }
        }
    }

    func cancel() { runner.cancel() }

    /// Shows a conversion (fresh or from the recent list) with its comparison.
    func show(_ record: GenerationRecord, original: URL? = nil) {
        result?.track.pause()
        result?.original?.pause()
        let voiceName = record.voiceName ?? "the new voice"
        let track = PlaybackTrack(url: record.audioURL, title: record.title,
                                  subtitle: "\(voiceName) · \(record.modelName) · \(Timecode.string(record.duration, tenths: false))")
        let originalURL = original ?? (source.map { $0.url.lastPathComponent == record.text ? $0.url : nil } ?? nil)
        var originalTrack: PlaybackTrack?
        if let u = originalURL, FileManager.default.fileExists(atPath: u.path) {
            originalTrack = source?.url == u ? source?.track : PlaybackTrack(url: u, title: u.deletingPathExtension().lastPathComponent)
        }
        result = Result(record: record, track: track, original: originalTrack)
        side = .converted
        saveDraft()
    }

    func dismissResult() {
        result?.track.pause()
        result = nil
        saveDraft()
    }

    /// Switches the comparison: the other side picks up at the same moment (the conversion keeps the timeline).
    func switchSide(to new: Side) {
        guard let result, new != side else { return }
        let from = side == .converted ? result.track : result.original
        let to = new == .converted ? result.track : result.original
        side = new
        guard let from, let to else { return }
        let t = from.currentTime
        let wasPlaying = from.isPlaying
        from.pause()
        if wasPlaying { to.play(from: t) } else { to.seek(to: t) }
    }

    func toggleFavorite(_ item: HistoryItem) {
        Task { try? await service.history.setFavorite(!item.favorite, for: item.id) }
    }

    // MARK: Recent

    private func observeRecent() {
        let observation = service.history.observe(HistoryQuery(kinds: [.voiceChange]), limit: 8)
        recentTask = Task { [weak self] in
            do {
                for try await page in observation {
                    guard let self else { return }
                    self.recent = page.items
                    self.recentTotal = page.total
                    if self.result == nil, let id = self.pendingResultID, let r = page.items.first(where: { $0.id == id })?.generation {
                        self.pendingResultID = nil
                        self.show(r, original: self.source?.url)
                    }
                }
            } catch {}
        }
    }

    // MARK: Draft

    @ObservationIgnored private var pendingResultID: UUID?

    private struct Draft: Codable {
        var choice: ModelChoice?
        var sourcePath: String?
        var voiceID: UUID?
        var parameters: ParamValues
        var post: PostProcessingOptions
        var pieceSeconds: Double
        var resultID: UUID?
    }

    private static let draftKey = "Changer.draft"

    private func setChoiceQuietly(_ c: ModelChoice?) {
        restoring = true
        choice = c
        restoring = false
    }

    private func saveDraft() {
        guard let drafts, !restoring else { return }
        let d = Draft(choice: choice, sourcePath: source?.url.path, voiceID: voiceID, parameters: parameters, post: post,
                      pieceSeconds: pieceSeconds, resultID: result?.record.id)
        if let data = try? JSONEncoder().encode(d) { drafts.set(data, forKey: Self.draftKey) }
    }

    private func restoreDraft() {
        guard let drafts, let data = drafts.data(forKey: Self.draftKey),
              let d = try? JSONDecoder().decode(Draft.self, from: data) else { return }
        restoring = true
        choice = d.choice; voiceID = d.voiceID; parameters = d.parameters; post = d.post; pieceSeconds = d.pieceSeconds
        if let path = d.sourcePath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            source = Source(url: url, info: nil, track: PlaybackTrack(url: url, title: url.deletingPathExtension().lastPathComponent))
            measure(url)
        }
        pendingResultID = d.resultID
        restoring = false
    }

    #if DEBUG
    @ObservationIgnored var pythonOverride: PythonRuntime.Lookup? { didSet { python = pythonOverride } }

    /// Fixtures and the headless runner: set state directly.
    func debugSet(choice: ModelChoice?, voiceID: UUID?, parameters: ParamValues = [:]) {
        setChoiceQuietly(choice)
        self.voiceID = voiceID
        self.parameters = parameters
    }

    func debugSetSource(_ url: URL, info: MediaInfo?, pieces: [AudioSegment]?) {
        segmentTask?.cancel()
        source = Source(url: url, info: info, track: PlaybackTrack(url: url, title: url.deletingPathExtension().lastPathComponent), pieces: pieces)
    }

    /// Waits for the source to be measured (headless runner).
    func waitForSource() async { await segmentTask?.value }
    #endif
}
