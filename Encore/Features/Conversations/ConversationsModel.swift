import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything the Conversations screen does, without the views: the working script (cast and lines), staging
/// (model, language, pauses, settings), importing and exporting scripts, rendering through the service, auditioning
/// one line, and knowing which lines are already rendered (the service reuses those, so re-renders are quick).
/// One instance lives for the app's lifetime (`deps.screenModel("Conversations")`); the script survives relaunch.
@MainActor @Observable
final class ConversationsModel {
    let service: EncoreService
    let settings: AppSettings
    let voices: VoiceLibrary
    let pronunciations: PronunciationStore
    let shelf: ModelShelf
    let runner: JobRunner
    /// Auditions run separately, so a line can be heard while the script is being edited.
    let auditionRunner: JobRunner
    @ObservationIgnored let editor = ScriptEditorController()
    @ObservationIgnored private let drafts: UserDefaults?

    // MARK: State

    var script = ConversationScript() { didSet { saveDraft() } }
    /// Color slot per speaker (index into `CastPalette`), kept stable as speakers come and go.
    private(set) var tints: [UUID: Int] = [:]
    var pauseSeconds: Double = 0.4 { didSet { saveDraft() } }
    var choice: ModelChoice? {
        didSet { if choice?.modelID != oldValue?.modelID, !restoring { draftModelRetired = false; modelChanged() }; saveDraft() }
    }
    var language: String? { didSet { saveDraft() } }
    var parameters: ParamValues = [:] { didSet { saveDraft() } }
    var post: PostProcessingOptions { didSet { saveDraft() } }
    var reuseLines = true { didSet { saveDraft() } }

    var editingLineID: UUID?
    /// The line whose pause-after panel is open (from the gap under it, or its menu).
    var pauseEditingLineID: UUID?
    var showTuning = false
    var importReport: ImportReport?

    private(set) var result: Rendered?
    /// What each line sounded like last time it was rendered (or auditioned): if it still matches, the service
    /// reuses that audio instead of generating the line again.
    private(set) var renderedKeys: [UUID: String] = [:]
    private(set) var auditioningLineID: UUID?
    @ObservationIgnored let auditionPlayer = AudioPlayer(title: "Audition")
    private(set) var auditionedLineID: UUID?
    private(set) var isPrepared = false
    /// The restored draft named a model that is no longer in the catalog; the screen says so until dismissed.
    var draftModelRetired = false

    struct ImportReport: Equatable {
        var fileName: String
        var layout: ConversationImporter.Layout
        var notes: [String]
        var speakers: Int
        var lines: Int
        var castFromLibrary: [String]
    }

    struct Rendered {
        var record: GenerationRecord
        var track: PlaybackTrack
        var reused: Int
        var lines: Int
    }

    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var auditionFile: URL?
    @ObservationIgnored private var pendingResultID: UUID?
    @ObservationIgnored private var pendingReused = 0

    init(service: EncoreService, settings: AppSettings, voices: VoiceLibrary, pronunciations: PronunciationStore,
         shelf: ModelShelf, drafts: UserDefaults?) {
        self.service = service
        self.settings = settings
        self.voices = voices
        self.pronunciations = pronunciations
        self.shelf = shelf
        self.drafts = drafts
        self.runner = JobRunner(runtime: service.runtime)
        self.auditionRunner = JobRunner(runtime: service.runtime)
        self.post = settings.postProcessing
        restoreDraft()
    }

    convenience init(deps: AppDependencies) {
        self.init(service: deps.service, settings: deps.settings, voices: deps.voices, pronunciations: deps.pronunciations,
                  shelf: deps.modelShelf, drafts: deps.drafts)
    }

    isolated deinit {
        if let auditionFile { try? FileManager.default.removeItem(at: auditionFile) }
    }

    func prepare() async {
        await shelf.waitForScan()
        let retired = choice.map { service.catalog.model($0.modelID)?.tasks.contains(.tts) != true } ?? false
        if retired { setChoiceQuietly(nil) }
        if choice == nil {
            let requires: ModelRequirement = usesLibraryVoices ? .cloning : []
            if let initial = shelf.initialChoice(for: .tts, requiring: requires, feature: .conversation, settings: settings)
                ?? shelf.initialChoice(for: .tts, feature: .conversation, settings: settings) {
                setChoiceQuietly(initial)
            }
        }
        if retired {
            // The draft's model left the catalog: recast its model voices and drop its settings, as a model switch does.
            draftModelRetired = true
            modelChanged()
        }
        if let id = pendingResultID {
            pendingResultID = nil
            if let item = try? await service.history.item(id), let r = item.generation { showResult(r, reused: 0) }
        }
        isPrepared = true
    }

    // MARK: Derived

    var manifest: ModelManifest? { choice.flatMap { service.catalog.model($0.modelID) } }

    var isDownloaded: Bool {
        guard let m = manifest else { return false }
        return shelf.isDownloaded(m, variantID: choice?.variantID)
    }

    var needsFirstModel: Bool { shelf.hasScanned && !shelf.hasDownloadedModel(for: .tts) }

    var speakers: [ConversationScript.Speaker] { script.speakers }
    var lines: [ConversationScript.Line] { script.lines }

    func speaker(_ id: UUID) -> ConversationScript.Speaker? { script.speakers.first { $0.id == id } }
    func tint(_ speakerID: UUID) -> Color { CastPalette.color(tints[speakerID] ?? 0) }
    func lineCount(for speakerID: UUID) -> Int { script.lines.filter { $0.speakerID == speakerID }.count }

    /// Some speaker who has lines is cast with a library voice, so the model must clone.
    var usesLibraryVoices: Bool {
        let speaking = Set(script.lines.map(\.speakerID))
        return script.speakers.contains { s in
            if case .library = s.voice { return speaking.contains(s.id) }
            return false
        }
    }

    var cloningProblem: (names: [String], suggestion: ModelManifest?)? {
        guard let m = manifest, !m.capabilities.cloning, usesLibraryVoices else { return nil }
        let names = script.speakers.filter { if case .library = $0.voice { true } else { false } }.map(\.name)
        let suggestion = shelf.manifests(for: .tts, requiring: .cloning).first(where: shelf.isAnyVariantDownloaded)
        return (names, suggestion)
    }

    /// Speakers sharing one voice (they'd sound alike), as name groups.
    var sharedVoices: [[String]] {
        let speaking = Set(script.lines.map(\.speakerID))
        let groups = Dictionary(grouping: script.speakers.filter { speaking.contains($0.id) }, by: \.voice)
        return groups.values.filter { $0.count > 1 }.map { $0.map(\.name) }
    }

    var spokenLines: [ConversationScript.Line] { script.lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// A parser for highlighting and checking lines, from the model's tags and the voices it can speak in.
    var parser: ScriptParser {
        guard let m = manifest else { return ScriptParser() }
        return ScriptParser(vocabulary: TagVocabulary(manifest: m),
                            voices: ScriptVoiceDirectory(library: m.capabilities.cloning ? voices.voices : [], presets: m.presetVoices))
    }

    /// The first line problem that stops a render (an error from the planner), with the line's number.
    var lineProblem: (index: Int, message: String)? {
        guard let m = manifest else { return nil }
        let library = voices.voices
        let entries = pronunciations.entries.filter(\.enabled)
        for (i, line) in script.lines.enumerated() where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var r = SpeechRequest(modelID: m.id, text: line.text)
            r.voice = speaker(line.speakerID)?.voice ?? .automatic
            let plan = ScriptPlanner(request: r, manifest: m, library: library, pronunciations: entries).plan(line.text)
            if let name = plan.parsed.unknownVoiceNames.first { return (i, "Line \(i + 1): no voice called “\(name)”.") }
            if let e = plan.issues.first(where: { $0.severity == .error }) { return (i, "Line \(i + 1): \(e.message)") }
        }
        return nil
    }

    var blockedReason: String? {
        guard let m = manifest else { return "Choose a model to perform with." }
        if shelf.hasScanned, !isDownloaded { return "Download the model first." }
        if spokenLines.isEmpty { return script.lines.isEmpty ? "Write or import a script." : "Every line is empty." }
        if let c = cloningProblem { return "\(m.name) can't clone, and \(ListFormatter.localizedString(byJoining: c.names)) \(c.names.count == 1 ? "uses" : "use") a library voice." }
        if let p = lineProblem { return p.message }
        return nil
    }

    /// How many spoken lines will actually be generated (the rest are reused).
    var pendingLines: Int { spokenLines.filter { !isRendered($0) }.count }

    /// Only what's new: how many lines will be generated, when some are already generated and will be reused.
    /// Nothing when every line is to be generated (the usual first time).
    var idleNote: String? {
        guard manifest != nil, reuseLines, !spokenLines.isEmpty else { return nil }
        let n = spokenLines.count
        let pending = pendingLines
        if pending == n { return nil }
        if pending == 0 { return "Nothing new to generate" }
        return "\(pending) of \(n) lines to generate"
    }

    /// Some spoken line is already generated and will be reused, so the ones still to generate are worth marking.
    var hasReusableLines: Bool { reuseLines && spokenLines.contains { isRendered($0) } }

    /// Rough running time: speech at ~14 characters a second plus the pauses.
    var estimatedSeconds: TimeInterval {
        let speech = spokenLines.reduce(0.0) { $0 + Double($1.text.count) / 14 }
        let pauses = spokenLines.dropLast().reduce(0.0) { $0 + ($1.pauseAfter ?? pauseSeconds) }
        return speech + pauses
    }

    // MARK: Line state

    enum LineState: Equatable { case empty, pending, ready, rendering, done }

    func state(of line: ConversationScript.Line) -> LineState {
        if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if runner.isRunning, let current = renderingIndex {
            let spoken = spokenLines
            if let i = spoken.firstIndex(where: { $0.id == line.id }) {
                if i < current { return .done }
                if i == current { return .rendering }
            }
        }
        if auditioningLineID == line.id { return .rendering }
        return isRendered(line) && reuseLines ? .ready : .pending
    }

    func isRendered(_ line: ConversationScript.Line) -> Bool { renderedKeys[line.id] == key(for: line) }

    /// Which spoken line is being rendered (0-based), from the service's "Line 3 of 12 (Mira)" stage.
    var renderingIndex: Int? {
        guard runner.isRunning, let stage = runner.stage else { return nil }
        if stage.hasPrefix("Line ") {
            let n = stage.dropFirst(5).prefix { $0.isNumber }
            return Int(n).map { $0 - 1 }
        }
        if stage.hasPrefix("Reused") || stage.hasPrefix("Saving") || stage.hasPrefix("Normal") || stage.hasPrefix("Tighten") { return spokenLines.count }
        return nil
    }

    /// Everything that shapes a line's audio (mirrors what the service keys its line cache on).
    private func key(for line: ConversationScript.Line) -> String {
        guard let m = manifest else { return "" }
        let voice = speaker(line.speakerID)?.voice ?? .automatic
        var parts = [m.id, shelf.preferredVariant(m, requested: choice?.variantID).id, language ?? "", "\(voice)", line.text]
        parts += ParameterValues.normalized(parameters, for: m).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        if case .library(let id) = voice, let v = voices.voice(id) { parts.append("\(v.transcript)|\(v.duration)") }
        for e in pronunciations.entries where e.enabled { parts.append("\(e.term)>\(e.replacement)|\(e.caseSensitive)") }
        return parts.joined(separator: "\u{1F}")
    }

    // MARK: Editing the cast

    @discardableResult
    func addSpeaker(named name: String? = nil) -> UUID {
        var s = ConversationScript.Speaker(name: name ?? nextSpeakerName())
        s.voice = suggestedVoice(index: script.speakers.count)
        tints[s.id] = nextTint()
        script.speakers.append(s)
        return s.id
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = script.speakers.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        script.speakers[i].name = clean.isEmpty ? script.speakers[i].name : clean
    }

    func setVoice(_ voice: VoiceSelection, for id: UUID) {
        guard let i = script.speakers.firstIndex(where: { $0.id == id }) else { return }
        script.speakers[i].voice = voice
    }

    /// Removes a speaker and their lines.
    func removeSpeaker(_ id: UUID) {
        script.lines.removeAll { $0.speakerID == id }
        script.speakers.removeAll { $0.id == id }
        tints[id] = nil
    }

    private func nextSpeakerName() -> String {
        var n = script.speakers.count + 1
        while script.speakers.contains(where: { $0.name == "Speaker \(n)" }) { n += 1 }
        return "Speaker \(n)"
    }

    private func nextTint() -> Int {
        let used = Set(tints.values)
        return (0..<CastPalette.count).first { !used.contains($0) } ?? tints.count % CastPalette.count
    }

    /// A distinct default voice for the n-th speaker: one of the model's own voices if it has them.
    private func suggestedVoice(index: Int, avoiding taken: Set<VoiceSelection> = []) -> VoiceSelection {
        guard let m = manifest, !m.presetVoices.isEmpty else { return .automatic }
        var presets = m.presetVoices
        if let language { presets = presets.filter { $0.language == language } + presets.filter { $0.language != language } }
        else if let first = presets.first?.language { presets = presets.filter { $0.language == first } + presets.filter { $0.language != first } }
        // Alternate voices so neighbors differ (a manifest may list all women, then all men, per language).
        let byGender = Dictionary(grouping: presets, by: { $0.gender ?? "" })
        var interleaved: [PresetVoice] = []
        let groups = byGender.keys.sorted().map { byGender[$0]! }
        for i in 0..<(groups.map(\.count).max() ?? 0) { for g in groups where i < g.count { interleaved.append(g[i]) } }
        let free = interleaved.filter { p in !taken.contains(.preset(p.id)) && !script.speakers.contains { $0.voice == .preset(p.id) } }
        return .preset((free.first ?? interleaved[index % interleaved.count]).id)
    }

    // MARK: Editing lines

    /// Adds a line after `after` (or at the end), for the speaker who'd naturally talk next.
    @discardableResult
    func addLine(after: UUID? = nil, speaker: UUID? = nil, text: String = "") -> UUID {
        if script.speakers.isEmpty { addSpeaker(); addSpeaker() }
        let index = after.flatMap { id in script.lines.firstIndex { $0.id == id } }.map { $0 + 1 } ?? script.lines.count
        let previous = index > 0 ? script.lines[index - 1].speakerID : nil
        let who = speaker ?? nextSpeaker(after: previous)
        let line = ConversationScript.Line(speakerID: who, text: text)
        script.lines.insert(line, at: index)
        return line.id
    }

    private func nextSpeaker(after previous: UUID?) -> UUID {
        guard let previous, let i = script.speakers.firstIndex(where: { $0.id == previous }) else { return script.speakers[0].id }
        // The speaker who spoke before the previous one, if there's a back-and-forth; else the next in the cast.
        let spoken = script.lines.map(\.speakerID)
        if let last = spoken.lastIndex(of: previous), last > 0 {
            let before = spoken[..<last].last { $0 != previous }
            if let before { return before }
        }
        return script.speakers[(i + 1) % script.speakers.count].id
    }

    func setText(_ text: String, for id: UUID) {
        guard let i = script.lines.firstIndex(where: { $0.id == id }), script.lines[i].text != text else { return }
        script.lines[i].text = text
    }

    func setSpeaker(_ speakerID: UUID, for id: UUID) {
        guard let i = script.lines.firstIndex(where: { $0.id == id }) else { return }
        script.lines[i].speakerID = speakerID
    }

    func setPause(_ seconds: Double?, after id: UUID) {
        guard let i = script.lines.firstIndex(where: { $0.id == id }) else { return }
        script.lines[i].pauseAfter = seconds.map { (($0 * 20).rounded() / 20) }
    }

    func deleteLine(_ id: UUID) {
        if editingLineID == id { editingLineID = nil }
        if pauseEditingLineID == id { pauseEditingLineID = nil }
        script.lines.removeAll { $0.id == id }
    }

    func moveLine(_ id: UUID, by offset: Int) {
        guard let i = script.lines.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(0, i + offset), script.lines.count - 1)
        guard j != i else { return }
        let line = script.lines.remove(at: i)
        script.lines.insert(line, at: j)
    }

    /// Drag and drop: puts `id` where `target` is.
    func moveLine(_ id: UUID, before target: UUID) {
        guard id != target, let i = script.lines.firstIndex(where: { $0.id == id }) else { return }
        let line = script.lines.remove(at: i)
        let j = script.lines.firstIndex { $0.id == target } ?? script.lines.count
        script.lines.insert(line, at: j)
    }

    /// Splits a line at its line breaks (Return while editing marks the spot), or into sentences when it has none.
    func splitLine(_ id: UUID) {
        guard let i = script.lines.firstIndex(where: { $0.id == id }) else { return }
        let line = script.lines[i]
        var parts = line.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count < 2 { parts = Self.sentences(line.text) }
        guard parts.count > 1 else { return }
        var replacement: [ConversationScript.Line] = []
        for (k, p) in parts.enumerated() {
            var l = k == 0 ? line : ConversationScript.Line(speakerID: line.speakerID, text: p)
            l.text = p
            l.pauseAfter = k == parts.count - 1 ? line.pauseAfter : nil
            replacement.append(l)
        }
        script.lines.replaceSubrange(i...i, with: replacement)
    }

    /// Joins a line with the next one (keeping this line's speaker).
    func mergeWithNext(_ id: UUID) {
        guard let i = script.lines.firstIndex(where: { $0.id == id }), i + 1 < script.lines.count else { return }
        let next = script.lines.remove(at: i + 1)
        script.lines[i].text = [script.lines[i].text, next.text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        script.lines[i].pauseAfter = next.pauseAfter
        if editingLineID == next.id { editingLineID = id }
    }

    func canMerge(_ id: UUID) -> Bool { (script.lines.firstIndex { $0.id == id }).map { $0 + 1 < script.lines.count } ?? false }

    func canSplit(_ line: ConversationScript.Line) -> Bool {
        line.text.contains(where: \.isNewline) || Self.sentences(line.text).count > 1
    }

    /// Finishing an edit: line breaks typed into the line split it there.
    func endEditing() {
        guard let id = editingLineID else { return }
        editingLineID = nil
        if let line = script.lines.first(where: { $0.id == id }), line.text.contains(where: \.isNewline) { splitLine(id) }
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        // Keep a trailing pause tag with its sentence rather than as a line of its own.
        var merged: [String] = []
        for s in out {
            if s.hasPrefix("["), s.hasSuffix("]"), !merged.isEmpty { merged[merged.count - 1] += " " + s } else { merged.append(s) }
        }
        return merged
    }

    func newScript() {
        editingLineID = nil
        pauseEditingLineID = nil
        importReport = nil
        pendingUnnamedImport = nil
        script = ConversationScript()
        tints = [:]
        renderedKeys = [:]
    }

    /// A small two-hander to start from.
    func startWriting() {
        newScript()
        let a = addSpeaker(named: "Ada"), b = addSpeaker(named: "Ben")
        let first = addLine(speaker: a, text: "")
        _ = b
        editingLineID = first
    }

    // MARK: Import and export

    static let scriptTypes: [UTType] = [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText,
                                        UTType(filenameExtension: "fountain") ?? .plainText]

    /// Imports a script. One without speaker names waits in `pendingUnnamedImport` until the user says who reads it
    /// (`finishUnnamedImport(_:)`); a script with names is applied straight away.
    func importScript(from url: URL) throws {
        let imported = try ConversationImporter.importFile(at: url)
        if imported.asksAboutSpeakers {
            dismissImportReport()  // an earlier import's report would otherwise sit beside the question
            pendingUnnamedImport = PendingUnnamedImport(result: imported, fileName: url.lastPathComponent)
        } else {
            pendingUnnamedImport = nil
            apply(imported, fileName: url.lastPathComponent)
        }
    }

    /// A script without speaker names, imported but not applied until the user chooses one voice or alternating
    /// speakers. The working script is untouched meanwhile.
    struct PendingUnnamedImport {
        var result: ConversationImporter.Result
        var fileName: String
        var paragraphs: Int { result.script.lines.count }
    }
    var pendingUnnamedImport: PendingUnnamedImport?

    /// Applies the waiting import with the user's answer.
    func finishUnnamedImport(_ choice: ConversationImporter.UnnamedSpeakers) {
        guard let pending = pendingUnnamedImport else { return }
        pendingUnnamedImport = nil
        apply(pending.result.withUnnamedSpeakers(choice), fileName: pending.fileName)
    }

    /// Drops the waiting import; the working script stays as it was.
    func cancelUnnamedImport() { pendingUnnamedImport = nil }

    /// Replaces the working script with an imported one; speakers named like a library voice get that voice (when
    /// the model clones), the rest get distinct voices of the model's own.
    func apply(_ imported: ConversationImporter.Result, fileName: String) {
        if !script.lines.isEmpty { beforeImport = (script, tints) }
        editingLineID = nil
        var s = imported.script
        tints = [:]
        var fromLibrary: [String] = []
        let canClone = manifest?.capabilities.cloning ?? false
        var taken: Set<VoiceSelection> = []
        for i in s.speakers.indices {
            tints[s.speakers[i].id] = i % CastPalette.count
            if canClone, let v = voices.voices.first(where: { $0.name.caseInsensitiveCompare(s.speakers[i].name) == .orderedSame }) {
                s.speakers[i].voice = .library(v.id)
                fromLibrary.append(v.name)
            }
        }
        script = s
        for i in s.speakers.indices where script.speakers[i].voice == .automatic {
            let v = suggestedVoice(index: i, avoiding: taken)
            script.speakers[i].voice = v
            taken.insert(v)
        }
        importReport = ImportReport(fileName: fileName, layout: imported.layout, notes: imported.notes,
                                    speakers: s.speakers.count, lines: s.lines.count, castFromLibrary: fromLibrary)
    }

    /// The script an import replaced, until the import is accepted or undone.
    @ObservationIgnored private var beforeImport: (script: ConversationScript, tints: [UUID: Int])?
    var canUndoImport: Bool { importReport != nil && beforeImport != nil }

    func undoImport() {
        guard let b = beforeImport else { return }
        script = b.script
        tints = b.tints
        beforeImport = nil
        importReport = nil
    }

    func dismissImportReport() {
        beforeImport = nil
        importReport = nil
    }

    var exportText: String { ConversationImporter.text(for: script) }

    func exportScript(completion: @escaping (Result<String, Error>) -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]
        let title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = AudioExportActions.sanitized(title.isEmpty ? "Conversation" : title) + ".txt"
        panel.title = "Export script"
        let data = Data(exportText.utf8)
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); completion(.success(url.lastPathComponent)) } catch { completion(.failure(error)) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    // MARK: Rendering

    private func request(for lines: [ConversationScript.Line]) -> ConversationRequest? {
        guard let m = manifest, let choice else { return nil }
        var s = script
        s.lines = lines
        var r = ConversationRequest(modelID: m.id, script: s)
        r.variantID = shelf.preferredVariant(m, requested: choice.variantID).id
        r.pauseSeconds = pauseSeconds
        r.language = language
        r.parameters = ParameterValues.normalized(parameters, for: m)
        r.post = post
        r.reuseRenderedLines = reuseLines
        return r
    }

    func render() {
        guard blockedReason == nil, !runner.isBusy, let m = manifest, let r = request(for: script.lines) else { return }
        endEditing()
        let keys = Dictionary(spokenLines.map { ($0.id, key(for: $0)) }, uniquingKeysWith: { a, _ in a })
        let total = spokenLines.count
        pendingReused = 0
        let service = self.service
        runner.start(.conversation, model: m, variantID: r.variantID) {
            service.renderConversation(r)
        } onEvent: { [weak self] event in
            guard let self else { return }
            switch event {
            case .stage(let s):
                if s.hasPrefix("Reused "), let n = Int(s.dropFirst(7).prefix { $0.isNumber }) { self.pendingReused = n }
            case .finished(let record):
                self.renderedKeys.merge(keys) { $1 }
                withStageAnimation(Theme.Motion.entrance) { self.showResult(record, reused: self.pendingReused, lines: total) }
            default: break
            }
        }
    }

    func cancel() { runner.cancel() }

    private func showResult(_ record: GenerationRecord, reused: Int, lines: Int? = nil) {
        result?.track.pause()
        let n = lines ?? record.text.split(separator: "\n").filter { $0.contains(":") && !$0.hasPrefix("Title:") }.count
        let track = PlaybackTrack(url: record.audioURL, title: record.title,
                                  subtitle: "\(record.voiceName ?? "") · \(record.modelName)")
        result = Rendered(record: record, track: track, reused: reused, lines: n)
        saveDraft()
    }

    func dismissResult() {
        result?.track.pause()
        result = nil
        saveDraft()
    }

    /// Renders one line on its own and plays it. The line lands in the service's line cache, so the full render
    /// reuses it; the one-line take itself isn't kept in History.
    func audition(_ id: UUID) {
        guard let line = script.lines.first(where: { $0.id == id }), !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !auditionRunner.isBusy, let m = manifest, var r = request(for: [line]) else { return }
        if blockedReason != nil, cloningProblem != nil || !isDownloaded { return }
        r.script.title = "Audition"
        r.saveToHistory = false
        r.post = PostProcessingOptions()
        r.post.normalizeLoudness = post.normalizeLoudness
        r.post.targetLUFS = post.targetLUFS
        auditionPlayer.stop()
        auditioningLineID = id
        let key = key(for: line)
        let service = self.service
        let request = r
        auditionRunner.start(.conversation, model: m, variantID: r.variantID) {
            service.renderConversation(request)
        } onEvent: { [weak self] event in
            guard let self, case .finished(let record) = event else { return }
            self.renderedKeys[id] = key
            self.auditionedLineID = id
            Task { await self.keepAndPlay(record) }
        }
        watchAudition()
    }

    private func watchAudition() {
        Task { [weak self] in
            await self?.auditionRunner.waitUntilIdle()
            self?.auditioningLineID = nil
        }
    }

    /// Plays the audition (rendered without a History record; its file is ours to delete).
    private func keepAndPlay(_ record: GenerationRecord) async {
        let url = record.audioURL
        if let old = auditionFile, old != url { try? FileManager.default.removeItem(at: old) }
        auditionFile = url
        let name = script.lines.firstIndex { $0.id == auditionedLineID }.map { "Line \($0 + 1)" } ?? "Audition"
        try? await auditionPlayer.load(url: url, title: name)
        auditionPlayer.subtitle = "Audition · not saved"
        #if DEBUG
        if Self.silentAuditions { return }
        #endif
        auditionPlayer.play()
    }

    /// The audition's temporary file, while it exists.
    var auditionURL: URL? { auditionFile }

    // MARK: Model changes

    private func modelChanged() {
        parameters = [:]
        guard let m = manifest else { return }
        if let l = language, !m.languages.contains(where: { $0.code == l }) { language = nil }
        // Model voices don't carry over; library voices do (the banner says when the model can't clone).
        var taken: Set<VoiceSelection> = []
        for i in script.speakers.indices {
            if case .preset(let p) = script.speakers[i].voice, !m.presetVoices.contains(where: { $0.id == p }) {
                script.speakers[i].voice = .automatic
            }
        }
        for i in script.speakers.indices where script.speakers[i].voice == .automatic && !m.presetVoices.isEmpty {
            let v = suggestedVoice(index: i, avoiding: taken)
            script.speakers[i].voice = v
            taken.insert(v)
        }
    }

    func switchToCloningModel() {
        guard let m = cloningProblem?.suggestion else { return }
        choice = ModelChoice(modelID: m.id, variantID: shelf.preferredVariant(m).id)
    }

    private func setChoiceQuietly(_ c: ModelChoice?) {
        restoring = true
        choice = c
        restoring = false
    }

    // MARK: Draft

    private struct Draft: Codable {
        var script: ConversationScript
        var tints: [UUID: Int]
        var pauseSeconds: Double
        var choice: ModelChoice?
        var language: String?
        var parameters: ParamValues
        var post: PostProcessingOptions
        var reuseLines: Bool
        var resultID: UUID?
    }

    private static let draftKey = "Conversations.draft"

    private func saveDraft() {
        guard let drafts, !restoring else { return }
        let d = Draft(script: script, tints: tints, pauseSeconds: pauseSeconds, choice: choice, language: language,
                      parameters: parameters, post: post, reuseLines: reuseLines, resultID: result?.record.id)
        if let data = try? JSONEncoder().encode(d) { drafts.set(data, forKey: Self.draftKey) }
    }

    private func restoreDraft() {
        guard let drafts, let data = drafts.data(forKey: Self.draftKey),
              let d = try? JSONDecoder().decode(Draft.self, from: data) else { return }
        restoring = true
        script = d.script; tints = d.tints; pauseSeconds = d.pauseSeconds; choice = d.choice; language = d.language
        parameters = d.parameters; post = d.post; reuseLines = d.reuseLines
        pendingResultID = d.resultID
        restoring = false
    }

    #if DEBUG
    /// The headless runner never plays audio out loud.
    static var silentAuditions = false

    func debugSet(choice: ModelChoice?, script: ConversationScript? = nil, pause: Double = 0.4) {
        setChoiceQuietly(choice)
        if let script {
            self.script = script
            tints = Dictionary(uniqueKeysWithValues: script.speakers.enumerated().map { ($1.id, $0 % CastPalette.count) })
        }
        pauseSeconds = pause
    }

    func debugShowResult(_ record: GenerationRecord, reused: Int, lines: Int) { showResult(record, reused: reused, lines: lines) }
    func debugMarkRendered(_ ids: [UUID]) { for l in script.lines where ids.contains(l.id) { renderedKeys[l.id] = key(for: l) } }
    #endif
}

/// Speaker colors: deep candy shades, readable as text on the cream stage, none of them the warning honey or the error cherry.
enum CastPalette {
    static let hexes: [UInt32] = [0xB8440A, 0x177A73, 0xB2386F, 0x2D63BB, 0x7A4FD0, 0x667510, 0x2A7D3C, 0x55657E]
    static var count: Int { hexes.count }
    static func color(_ i: Int) -> Color { Color(hex: hexes[((i % count) + count) % count]) }
}
