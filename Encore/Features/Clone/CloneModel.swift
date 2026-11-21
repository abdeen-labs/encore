import EncoreCore
import SwiftUI

/// Everything the Clone screen does, without the views: the source (a dropped file of any length, or a
/// recording), the selected stretch, its transcript (transcribed locally as soon as the selection settles),
/// the voice's details and the consent tick, saving the selection as a library voice, and hearing it.
/// One instance lives for the app's lifetime (`deps.screenModel("Clone")`), so the flow survives switching sections.
@MainActor @Observable
final class CloneModel {
    struct Source: Equatable {
        enum Kind: Equatable { case file, recording }
        var url: URL
        var name: String
        var kind: Kind
        var duration: TimeInterval
        var sampleRate: Double
        var hasVideo: Bool
        var fileSize: Int64?
    }

    enum SourceMode: String, CaseIterable, Hashable { case file = "Drop a file", record = "Record" }

    enum TranscriptState: Equatable {
        case idle
        /// The selection is settling; a transcription will start shortly.
        case pending
        case transcribing(ClosedRange<TimeInterval>)
        case ready(ClosedRange<TimeInterval>, modelName: String)
        /// The user edited the transcript, then moved the selection: offer to transcribe again rather than overwrite.
        case stale
        case noModel
        case failed(String)
    }

    let service: EncoreService
    let voices: VoiceLibrary
    let settings: AppSettings
    let shelf: ModelShelf
    let tryout: VoiceTryout

    // MARK: State

    var mode: SourceMode = .file
    private(set) var source: Source?
    private(set) var isLoadingSource = false
    var sourceError: String?

    /// The stretch of the source to keep, in seconds.
    var selection: ClosedRange<TimeInterval> = 0...10 { didSet { if selection != oldValue { selectionChanged() } } }

    var transcript = "" { didSet { if !settingTranscript, transcript != oldValue { transcriptEdited = true } } }
    private(set) var transcriptEdited = false
    private(set) var transcriptState: TranscriptState = .idle

    var name = "" { didSet { if !settingName { nameEdited = true } } }
    var tags: [String] = []
    var language: String? { didSet { if !settingLanguage { languageEdited = true } } }
    var notes = ""
    var consent = false { didSet { consentAt = consent ? (consentAt ?? Date()) : nil } }
    private(set) var consentAt: Date?

    /// The cloning model the voice is being made for: sets the length guidance and performs "hear it".
    var modelChoice: ModelChoice? { didSet { if modelChoice != oldValue, let modelChoice { tryout.choice = modelChoice } } }

    private(set) var isSaving = false
    var saveError: String?
    private(set) var saved: Voice?
    private(set) var isPrepared = false

    @ObservationIgnored private(set) var recorder: AudioRecorder?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var transcription: Task<Void, Never>?
    @ObservationIgnored private var lastTranscribed: ClosedRange<TimeInterval>?
    @ObservationIgnored private var settingTranscript = false
    @ObservationIgnored private var settingName = false
    @ObservationIgnored private var settingLanguage = false
    @ObservationIgnored private var nameEdited = false
    @ObservationIgnored private var languageEdited = false
    /// The trimmer has suggested a stretch or the user moved it: when the trimmer reappears it keeps this selection.
    @ObservationIgnored private(set) var hasChosenSelection = false
    @ObservationIgnored private var transcriptionModelName: String?

    /// How long the selection must sit still before it is transcribed.
    @ObservationIgnored var settleDelay: Duration = .milliseconds(900)
    /// Snapshot fixtures turn this off so nothing reaches the (backend-less) service.
    @ObservationIgnored var autoTranscribe = true

    init(service: EncoreService, voices: VoiceLibrary, settings: AppSettings, shelf: ModelShelf) {
        self.service = service
        self.voices = voices
        self.settings = settings
        self.shelf = shelf
        tryout = VoiceTryout(service: service, shelf: shelf)
    }

    convenience init(deps: AppDependencies) {
        self.init(service: deps.service, voices: deps.voices, settings: deps.settings, shelf: deps.modelShelf)
    }

    func prepare() async {
        await shelf.waitForScan()
        if modelChoice == nil {
            // The last cloning model used, else the best downloaded one for references with transcripts.
            let preferred = ["qwen3-tts-base", "chatterbox-turbo", "voxcpm2", "chatterbox-multilingual", "omnivoice", "zonos3-mini"]
            let downloaded = shelf.manifests(for: .tts, requiring: .cloning).filter(shelf.isAnyVariantDownloaded)
            if settings.lastUsedModels[.cloning] == nil,
               let m = preferred.lazy.compactMap({ id in downloaded.first { $0.id == id } }).first {
                modelChoice = ModelChoice(modelID: m.id, variantID: shelf.preferredVariant(m).id)
            } else {
                modelChoice = shelf.initialChoice(for: .tts, requiring: .cloning, feature: .cloning, settings: settings)
            }
        }
        isPrepared = true
    }

    // MARK: Derived

    var modelManifest: ModelManifest? { modelChoice.flatMap { service.catalog.model($0.modelID) } }

    /// The reference length to aim for: the chosen model's, else 5–15 s.
    var target: ClosedRange<TimeInterval> {
        if let r = modelManifest?.reference { return r.minSeconds...r.maxSeconds }
        return 5...15
    }

    var length: TimeInterval { selection.upperBound - selection.lowerBound }

    enum LengthVerdict { case good, short, tooShort, tooLong }

    var lengthVerdict: LengthVerdict {
        if length > target.upperBound + 0.5 { return .tooLong }
        if length < 1.5 { return .tooShort }
        if length < target.lowerBound - 0.05 { return .short }
        return .good
    }

    var hasTranscriptionModel: Bool { !shelf.hasScanned || shelf.hasDownloadedModel(for: .stt) }

    var suggestedName: String {
        guard let source else { return "New voice" }
        switch source.kind {
        case .recording:
            return uniqueName("Recorded voice, \(Date().formatted(.dateTime.day().month(.abbreviated)))")
        case .file:
            var stem = source.url.deletingPathExtension().lastPathComponent
            stem = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            stem = stem.split(separator: " ").joined(separator: " ")
            stem = stem.prefix(1).uppercased() + stem.dropFirst()
            return uniqueName(stem.isEmpty ? "New voice" : String(stem.prefix(40)))
        }
    }

    /// Which step of the flow is current, for the cue sheet: 0 source, 1 trim, 2 words, 3 details, 4 consent, 5 saved.
    var currentStep: Int {
        if saved != nil { return 5 }
        guard source != nil else { return 0 }
        if lengthVerdict == .tooLong || lengthVerdict == .tooShort { return 1 }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 2 }
        if !consent { return 4 }
        return 4
    }

    /// Why Save can't run, or nil.
    var blockedReason: String? {
        guard source != nil else { return "Choose a recording first." }
        switch lengthVerdict {
        case .tooLong: return "Trim the clip to \(Int(target.upperBound)) seconds or less (it's \(Self.seconds(length)) now)."
        case .tooShort: return "Select at least a few seconds of speech."
        default: break
        }
        if case .transcribing = transcriptState { return "Transcribing the clip…" }
        if case .pending = transcriptState { return "Transcribing the clip…" }
        if !consent { return "Confirm you have the speaker's permission." }
        if isSaving { return "Saving…" }
        return nil
    }

    var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? suggestedName : n
    }

    // MARK: Source

    func load(_ url: URL, kind: Source.Kind = .file) async {
        sourceError = nil
        isLoadingSource = true
        defer { isLoadingSource = false }
        do {
            let info = try await AudioReader.probe(url)
            guard info.duration > 0.2 else { sourceError = "“\(url.lastPathComponent)” has no audio Encore can read."; return }
            discardRecording(except: url)
            resetDetails()
            source = Source(url: url, name: url.lastPathComponent, kind: kind, duration: info.duration, sampleRate: info.sampleRate,
                            hasVideo: info.hasVideo, fileSize: info.fileSize)
            hasChosenSelection = false
            lastTranscribed = nil
            // A first guess; the trimmer replaces it with the best-sounding stretch once it has read the file.
            let ideal = min(target.upperBound, max(target.lowerBound, (target.lowerBound + target.upperBound) / 2))
            selection = 0...min(info.duration, ideal)
            setName(suggestedName)
        } catch {
            sourceError = "Encore couldn't read “\(url.lastPathComponent)”: \(ErrorPresentation(error)?.message ?? error.localizedDescription)"
        }
    }

    /// The live recorder, created only when the user opens the Record panel (creating it never touches the microphone;
    /// only pressing Record does).
    func liveRecorder() -> AudioRecorder {
        if let recorder { return recorder }
        let r = AudioRecorder()
        r.maxDuration = 10 * 60
        recorder = r
        return r
    }

    func recordingFinished(_ url: URL) {
        Task { await load(url, kind: .recording) }
    }

    /// Back to an empty flow (the saved voice stays in the library).
    func startOver() {
        debounce?.cancel()
        transcription?.cancel()
        discardRecording(except: nil)
        source = nil
        saved = nil
        saveError = nil
        sourceError = nil
        resetDetails()
        tryout.reset()
        if let recorder, !recorder.isRecording { recorder.cancel() }
    }

    private func resetDetails() {
        setTranscript("")
        transcriptEdited = false
        transcriptState = .idle
        setName("")
        nameEdited = false
        tags = []
        settingLanguage = true; language = nil; settingLanguage = false
        languageEdited = false
        notes = ""
        consent = false
        saved = nil
        saveError = nil
    }

    private func discardRecording(except keep: URL?) {
        guard let s = source, s.kind == .recording, s.url != keep else { return }
        try? FileManager.default.removeItem(at: s.url)
    }

    // MARK: Selection and transcription

    /// The binding the trimmer edits; any edit (its suggestion or the user's) makes the selection the chosen one.
    var trimmerSelection: Binding<ClosedRange<TimeInterval>> {
        Binding { self.selection } set: { new in
            self.hasChosenSelection = true
            self.selection = new
        }
    }

    private func selectionChanged() {
        guard source != nil, saved == nil else { return }
        scheduleTranscription()
    }

    private func differsMaterially(_ a: ClosedRange<TimeInterval>, _ b: ClosedRange<TimeInterval>?) -> Bool {
        guard let b else { return true }
        return abs(a.lowerBound - b.lowerBound) > 0.3 || abs(a.upperBound - b.upperBound) > 0.3
    }

    /// Transcribes the selection once it has been still for `settleDelay` (and only if it moved materially).
    func scheduleTranscription(force: Bool = false) {
        debounce?.cancel()
        guard source != nil, autoTranscribe else { return }
        guard hasTranscriptionModel else { transcriptState = .noModel; return }
        guard lengthVerdict != .tooLong, lengthVerdict != .tooShort else {
            // Nothing worth transcribing yet; keep what's there.
            if case .pending = transcriptState { transcriptState = lastTranscribed == nil ? .idle : transcriptState }
            return
        }
        guard force || differsMaterially(selection, lastTranscribed) else { return }
        if transcriptEdited && !force {
            transcriptState = .stale
            return
        }
        if case .transcribing = transcriptState {} else { transcriptState = .pending }
        let delay = force ? Duration.zero : settleDelay
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.transcribe(self.selection)
        }
    }

    /// Transcribes `range` of the source now (replacing the transcript).
    func transcribe(_ range: ClosedRange<TimeInterval>) {
        guard let source else { return }
        transcription?.cancel()
        transcriptState = .transcribing(range)
        let service = self.service
        let languageHint = languageEdited ? language : nil
        transcription = Task { [weak self] in
            do {
                let modelName = (try? service.defaultTranscriptionModel().name) ?? "the transcription model"
                let t = try await service.transcribeReference(source.url, range: range, language: languageHint)
                guard let self, !Task.isCancelled, self.source?.url == source.url else { return }
                self.lastTranscribed = range
                self.setTranscript(t.text.trimmingCharacters(in: .whitespacesAndNewlines))
                self.transcriptEdited = false
                self.transcriptionModelName = modelName
                if !self.languageEdited, let l = VoiceLanguages.normalize(t.language) {
                    self.settingLanguage = true; self.language = l; self.settingLanguage = false
                }
                withStageAnimation { self.transcriptState = .ready(range, modelName: modelName) }
                // The selection moved while we worked: go again.
                if self.differsMaterially(self.selection, range) { self.scheduleTranscription() }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case ServiceError.noTranscriptionModel = error {
                    self.transcriptState = .noModel
                } else {
                    self.transcriptState = .failed(ErrorPresentation(error)?.message ?? error.localizedDescription)
                }
            }
        }
    }

    func retranscribe() {
        transcriptEdited = false
        scheduleTranscription(force: true)
    }

    private func setTranscript(_ t: String) { settingTranscript = true; transcript = t; settingTranscript = false }
    private func setName(_ n: String) { settingName = true; name = n; settingName = false }

    // MARK: Save

    /// Cuts the selection out of the source and saves it as a cloned voice.
    func save() async {
        guard blockedReason == nil, let source else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let fm = FileManager.default
        let clip = service.scratchDirectory.appendingPathComponent("clone-\(UUID().uuidString).wav")
        do {
            let range = max(0, selection.lowerBound)...min(source.duration, selection.upperBound)
            var audio = try await AudioReader.read(source.url, range: range)
            audio = AudioEdit.fade(audio, in: 0.01, out: 0.03)
            try AudioExporter.writeWAV(audio, to: clip, encoding: .pcm24)
            let voice = Voice(name: effectiveName, tags: tags, origin: .cloned,
                              transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                              language: language, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                              sourceModelID: modelChoice?.modelID, duration: audio.duration,
                              consentConfirmedAt: consentAt ?? Date())
            let made = try await voices.add(voice, referenceAudio: clip, move: true)
            debounce?.cancel()
            transcription?.cancel()
            withStageAnimation(Theme.Motion.entrance) { saved = made }
            tryout.prepare(for: made, preferredModel: modelChoice)
        } catch {
            try? fm.removeItem(at: clip)
            saveError = ErrorPresentation(error)?.message ?? error.localizedDescription
        }
    }

    // MARK: Helpers

    private func uniqueName(_ base: String) -> String {
        let names = Set(voices.voices.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    static func seconds(_ t: TimeInterval) -> String { String(format: "%.1f s", t) }

    #if DEBUG
    /// Fixtures and the headless runner.
    func debugSetSource(_ source: Source, selection: ClosedRange<TimeInterval>) {
        self.source = source
        self.selection = selection
        hasChosenSelection = true
        debounce?.cancel()
        transcriptState = .idle
        setName(suggestedName)
    }

    func debugSetTranscript(_ text: String, state: TranscriptState, edited: Bool = false) {
        debounce?.cancel()
        setTranscript(text)
        transcriptEdited = edited
        transcriptState = state
        if case .ready(let r, _) = state { lastTranscribed = r }
    }

    func debugSetSaved(_ voice: Voice) { saved = voice }
    #endif
}
