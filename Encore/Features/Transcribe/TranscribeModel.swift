import AppKit
import EncoreCore
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Everything the Transcribe screen does, without the views: the media, the model/language/timing settings,
/// transcribing through the service, the transcript on show (fresh or from history) and its exports.
/// One instance lives for the app's lifetime (`deps.screenModel("Transcribe")`); the setup survives relaunch.
@MainActor @Observable
final class TranscribeModel {
    let service: EncoreService
    let settings: AppSettings
    let shelf: ModelShelf
    let runner: JobRunner
    @ObservationIgnored private let drafts: UserDefaults?

    // MARK: State

    var choice: ModelChoice? { didSet { if choice?.modelID != oldValue?.modelID, !restoring { modelChanged() }; saveDraft() } }
    /// nil = automatic (detect the language).
    var language: String? { didSet { saveDraft() } }
    var timestamps: TimestampGranularity = .segment { didSet { saveDraft() } }
    var parameters: ParamValues = [:] { didSet { saveDraft() } }
    private(set) var source: Source?

    /// The transcript on show, and the media it came from (when it's still there).
    private(set) var record: TranscriptionRecord?
    private(set) var recordTrack: PlaybackTrack?
    /// Show the transcript with its timings (rows) or as prose. Switching never re-runs anything.
    var showTimings = true { didSet { saveDraft() } }
    /// Keep the playing segment in view.
    var follow = true
    var showTuning = false

    private(set) var recent: [HistoryItem] = []
    private(set) var recentTotal = 0
    private(set) var isPrepared = false

    struct Source: Equatable {
        var url: URL
        var info: MediaInfo?
        var track: PlaybackTrack
        var problem: String?
        static func == (a: Source, b: Source) -> Bool { a.url == b.url && a.info == b.info && a.problem == b.problem }
    }

    static let mediaTypes: [UTType] = [.audio, .movie, .audiovisualContent]

    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var recentTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRecordID: UUID?

    init(service: EncoreService, settings: AppSettings, shelf: ModelShelf, drafts: UserDefaults?) {
        self.service = service
        self.settings = settings
        self.shelf = shelf
        self.drafts = drafts
        self.runner = JobRunner(runtime: service.runtime)
        restoreDraft()
        observeRecent()
    }

    convenience init(deps: AppDependencies) {
        self.init(service: deps.service, settings: deps.settings, shelf: deps.modelShelf, drafts: deps.drafts)
    }

    isolated deinit { recentTask?.cancel(); probeTask?.cancel() }

    func prepare() async {
        await shelf.waitForScan()
        if let c = choice, service.catalog.model(c.modelID)?.tasks.contains(.stt) != true { setChoiceQuietly(nil) }
        if choice == nil, let initial = shelf.initialChoice(for: .stt, feature: .transcription, settings: settings) {
            setChoiceQuietly(initial)
        }
        isPrepared = true
    }

    // MARK: Derived

    var manifest: ModelManifest? { choice.flatMap { service.catalog.model($0.modelID) } }

    var isDownloaded: Bool {
        guard let m = manifest else { return false }
        return shelf.isDownloaded(m, variantID: choice?.variantID)
    }

    var needsFirstModel: Bool { shelf.hasScanned && !shelf.hasDownloadedModel(for: .stt) }

    /// What the picker asks of the model for the chosen timings.
    var requirement: ModelRequirement { timestamps == .word ? .wordTimestamps : [] }

    /// Where the job will run for these timings, once known.
    var plannedRuntime: RuntimeVerdict? {
        guard timestamps == .word else { return nil }
        return manifest.flatMap { shelf.runtime(for: $0, requiring: requirement) }
    }

    /// Where segment timings will run, once asked. Whisper's go to the Python helper when it is set up, because
    /// it returns sentence-length segments; otherwise they run natively.
    private(set) var segmentRuntime: RuntimeVerdict?

    func refreshSegmentRuntime() async {
        guard timestamps == .segment, let id = manifest?.id else { segmentRuntime = nil; return }
        let planned = await service.plannedRuntime(modelID: id, needs: .transcription,
                                                   prefers: EncoreService.transcriptionPreference(.segment))
        guard timestamps == .segment, manifest?.id == id else { return }
        switch planned {
        case .success(let runtime): segmentRuntime = .runs(runtime)
        case .failure(let error): segmentRuntime = .blocked(error)
        }
    }

    var blockedReason: String? {
        guard let m = manifest else { return "Choose a transcription model." }
        if shelf.hasScanned, !isDownloaded { return "\(m.name) isn't downloaded yet." }
        guard let source else { return "Add audio or video to transcribe." }
        if let p = source.problem { return p }
        if timestamps == .word, !m.capabilities.wordTimestamps { return "\(m.name) can't time each word. Choose segments, or another model." }
        if case .blocked(let e)? = plannedRuntime { return ErrorPresentation(e)?.title ?? "\(m.name) can't run here." }
        return nil
    }

    var idleNote: String? {
        guard let source, let m = manifest else { return nil }
        let length = source.info.map { Timecode.string($0.duration, tenths: false) } ?? "–:––"
        let lang = language.flatMap { code in m.languages.first { $0.code == code }?.name } ?? "language detected"
        let timing: String
        switch timestamps {
        case .none: timing = "no timings"
        case .segment: timing = "segment timings"
        case .word: timing = "word timings"
        }
        return "\(length) · \(lang) · \(timing) · \(m.name)"
    }

    var transcript: Transcript? { record?.transcript }

    var hasWordTimings: Bool { transcript?.segments.contains { !($0.words ?? []).isEmpty } ?? false }

    /// The model timed the audio in long blocks (native Whisper times each 30-second window as one segment).
    var hasCoarseSegments: Bool {
        guard let t = transcript, !t.segments.isEmpty, !hasWordTimings else { return false }
        let total = t.segments.reduce(0.0) { $0 + ($1.end - $1.start) }
        return total / Double(t.segments.count) > 12
    }

    /// Runs the shown transcript's media again with word timings (which also gives sentence-length segments).
    func rerunWithWords() {
        guard let record, FileManager.default.fileExists(atPath: record.sourcePath) else { return }
        let url = URL(fileURLWithPath: record.sourcePath)
        if source?.url.standardizedFileURL != url.standardizedFileURL { setSource(url) }
        timestamps = .word
        closeTranscript()
        Task { [weak self] in
            await self?.probeTask?.value
            guard let self else { return }
            if let m = self.manifest { await self.shelf.refreshRuntimes(for: [m], requiring: .wordTimestamps) }
            self.transcribe()
        }
    }

    var wordCount: Int {
        guard let t = transcript else { return 0 }
        return t.text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: Source

    func setSource(_ url: URL) {
        source = Source(url: url, info: nil, track: PlaybackTrack(url: url, title: url.lastPathComponent))
        saveDraft()
        probe(url)
    }

    func clearSource() {
        source?.track.pause()
        source = nil
        saveDraft()
    }

    private func probe(_ url: URL) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            do {
                let info = try await AudioReader.probe(url)
                guard let self, self.source?.url == url else { return }
                self.source?.info = info
                if info.duration < 0.2 { self.source?.problem = "There's no audio long enough to transcribe in that file." }
            } catch {
                guard let self, self.source?.url == url else { return }
                self.source?.problem = "Couldn't read \(url.lastPathComponent): \(ErrorPresentation.clip(error.localizedDescription))"
            }
        }
    }

    // MARK: Actions

    func transcribe() {
        guard blockedReason == nil, !runner.isBusy, let m = manifest, let choice, let source else { return }
        var r = TranscriptionRequest(modelID: m.id, mediaPath: source.url.path)
        r.variantID = shelf.preferredVariant(m, requested: choice.variantID).id
        r.language = language
        r.timestamps = timestamps
        r.parameters = ParameterValues.normalized(parameters, for: m)
        source.track.pause()
        let service = self.service
        let request = r
        runner.start(.transcription, model: m, variantID: r.variantID) {
            service.transcribe(request)
        } onEvent: { [weak self] event in
            guard let self, case .finished(let record) = event else { return }
            withStageAnimation(Theme.Motion.entrance) {
                self.open(record)
                if record.transcript.segments.isEmpty { self.showTimings = false }
            }
        }
    }

    func cancel() { runner.cancel() }

    /// Shows a transcription (fresh, or one from history).
    func open(_ record: TranscriptionRecord) {
        recordTrack?.pause()
        self.record = record
        let url = URL(fileURLWithPath: record.sourcePath)
        if FileManager.default.fileExists(atPath: url.path) {
            recordTrack = source?.url.standardizedFileURL == url.standardizedFileURL ? source?.track
                : PlaybackTrack(url: url, title: record.sourceName)
            recordTrack?.subtitle = "\(record.modelName) · \(record.transcript.language.map(languageName) ?? "language unknown")"
        } else {
            recordTrack = nil
        }
        saveDraft()
    }

    /// Back to the setup (the source stays, ready for another run).
    func closeTranscript() {
        recordTrack?.pause()
        record = nil
        recordTrack = nil
        saveDraft()
    }

    func languageName(_ code: String) -> String {
        for m in service.catalog.models(for: .stt) {
            if let l = m.languages.first(where: { $0.code == code }) { return l.name }
        }
        return code
    }

    /// The segment playing at `time` (binary search; segments are in order).
    static func segmentIndex(at time: TimeInterval, in segments: [Transcript.Segment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        var lo = 0, hi = segments.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let i = found, time <= segments[i].end + 0.6 else { return nil }
        return i
    }

    func seek(to segment: Transcript.Segment) {
        recordTrack?.play(from: segment.start)
    }

    // MARK: Copy and export

    func text(as format: TranscriptFormat) -> String {
        guard let t = transcript else { return "" }
        return TranscriptFormatter().string(t, as: format)
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(as: showTimings && !(transcript?.segments.isEmpty ?? true) ? .timestampedText : .text), forType: .string)
    }

    /// A save panel for `format`, then writes it. Calls back with the saved file's name, or an error message.
    func export(_ format: TranscriptFormat, completion: @escaping (Result<String, Error>) -> Void) {
        guard let record else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [Self.contentType(format)]
        let base = (record.sourceName as NSString).deletingPathExtension
        panel.nameFieldStringValue = AudioExportActions.sanitized(base + (format == .timestampedText ? " (timed)" : "")) + ".\(format.fileExtension)"
        panel.title = "Export \(format.label)"
        let data = TranscriptFormatter().data(record.transcript, as: format)
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                completion(.success(url.lastPathComponent))
            } catch {
                completion(.failure(error))
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    static func contentType(_ f: TranscriptFormat) -> UTType {
        switch f {
        case .text, .timestampedText: .plainText
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .plainText
        case .json: .json
        }
    }

    // MARK: Model changes

    private func modelChanged() {
        parameters = [:]
        if let l = language, let m = manifest, !m.languages.contains(where: { $0.code == l }) { language = nil }
        if timestamps == .word, let m = manifest, !m.capabilities.wordTimestamps { timestamps = .segment }
    }

    private func setChoiceQuietly(_ c: ModelChoice?) {
        restoring = true
        choice = c
        restoring = false
    }

    // MARK: Recent

    private func observeRecent() {
        let observation = service.history.observe(HistoryQuery(kinds: [.transcription]), limit: 30)
        recentTask = Task { [weak self] in
            do {
                for try await page in observation {
                    guard let self else { return }
                    self.recent = page.items
                    self.recentTotal = page.total
                    if self.record == nil, let id = self.pendingRecordID, let r = page.items.first(where: { $0.id == id })?.transcription {
                        self.pendingRecordID = nil
                        self.open(r)
                    }
                    // Keep the shown transcript in step with edits made elsewhere (e.g. History).
                    if let shown = self.record, let fresh = page.items.first(where: { $0.id == shown.id })?.transcription,
                       fresh.transcript != shown.transcript {
                        self.record = fresh
                    }
                }
            } catch {}
        }
    }

    func delete(_ id: UUID) {
        if record?.id == id { closeTranscript() }
        Task { try? await service.history.delete(id) }
    }

    // MARK: Draft

    private struct Draft: Codable {
        var choice: ModelChoice?
        var language: String?
        var timestamps: TimestampGranularity
        var parameters: ParamValues
        var sourcePath: String?
        var recordID: UUID?
        var showTimings: Bool
    }

    private static let draftKey = "Transcribe.draft"

    private func saveDraft() {
        guard let drafts, !restoring else { return }
        let d = Draft(choice: choice, language: language, timestamps: timestamps, parameters: parameters,
                      sourcePath: source?.url.path, recordID: record?.id, showTimings: showTimings)
        if let data = try? JSONEncoder().encode(d) { drafts.set(data, forKey: Self.draftKey) }
    }

    private func restoreDraft() {
        guard let drafts, let data = drafts.data(forKey: Self.draftKey),
              let d = try? JSONDecoder().decode(Draft.self, from: data) else { return }
        restoring = true
        choice = d.choice; language = d.language; timestamps = d.timestamps; parameters = d.parameters; showTimings = d.showTimings
        if let path = d.sourcePath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            source = Source(url: url, info: nil, track: PlaybackTrack(url: url, title: url.lastPathComponent))
            probe(url)
        }
        pendingRecordID = d.recordID
        restoring = false
    }

    #if DEBUG
    func debugSet(choice: ModelChoice?, language: String? = nil, timestamps: TimestampGranularity = .segment) {
        setChoiceQuietly(choice)
        self.language = language
        self.timestamps = timestamps
    }

    func debugSetSource(_ url: URL, info: MediaInfo?) {
        probeTask?.cancel()
        source = Source(url: url, info: info, track: PlaybackTrack(url: url, title: url.lastPathComponent))
    }

    func waitForSource() async { await probeTask?.value }
    #endif
}

extension AppDependencies {
    /// Shows a transcription on the Transcribe screen (e.g. History's "Open in Transcribe"): its transcript, player
    /// and exports, as if it had just been made.
    ///
    ///     deps.openInTranscribe(record)
    func openInTranscribe(_ record: TranscriptionRecord) {
        let model = screenModel("Transcribe") { TranscribeModel(deps: self) }
        model.open(record)
        router.go(.transcribe)
    }
}
