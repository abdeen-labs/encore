import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

// Pieces shared by Clone, Design and Voices: languages, the tag editor, the consent tick, the "hear it" panel,
// and casting a voice in Studio.

// MARK: - Languages

/// A voice's language is a plain ISO 639-1 code ("en"). Models name languages their own way ("english", "en",
/// "English"), so this maps between the two.
enum VoiceLanguages {
    static let codes = ["en", "zh", "ja", "ko", "de", "fr", "es", "it", "pt", "ru", "ar", "hi", "nl", "pl", "tr", "sv",
                        "da", "fi", "no", "el", "he", "id", "ms", "th", "vi", "uk", "cs", "hu", "ro"]

    private static let english = Locale(identifier: "en")

    static func name(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "Not set" }
        return english.localizedString(forLanguageCode: code) ?? code
    }

    /// "en", "EN", "english", "English" → "en". Unknown names come back lowercased.
    static func normalize(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty, raw != "auto" else { return nil }
        if codes.contains(raw) { return raw }
        let base = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? raw
        if codes.contains(base) { return base }
        if let c = codes.first(where: { name($0).lowercased() == raw }) { return c }
        return raw
    }

    /// The code `manifest` uses for a voice's language, or nil when the model doesn't list it.
    static func modelCode(for language: String?, in manifest: ModelManifest) -> String? {
        guard let lang = normalize(language) else { return nil }
        return manifest.languages.first { normalize($0.code) == lang || normalize($0.name) == lang }?.code
    }
}

/// Picks a voice's language from the common list (or "Not set").
struct VoiceLanguageMenu: View {
    var title: String? = "Language"
    @Binding var language: String?

    var body: some View {
        var options: [String?] = [nil] + VoiceLanguages.codes.map { Optional($0) }
        if let l = language, !VoiceLanguages.codes.contains(l) { options.append(l) }
        return MenuPicker(title, selection: $language, options: options) { VoiceLanguages.name($0) }
    }
}

// MARK: - Tags

/// Tags as removable chips, a field to add more (Return or comma), and a few of the library's tags to add with a click.
struct TagEditor: View {
    @Binding var tags: [String]
    var suggestions: [String] = []
    var placeholder = "Add a tag"

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var offered: [String] {
        let have = Set(tags.map { $0.lowercased() })
        return Array(suggestions.filter { !have.contains($0.lowercased()) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Chip(tag, onRemove: { withStageAnimation(Theme.Motion.quick) { tags.removeAll { $0 == tag } } })
                }
                HStack(spacing: 5) {
                    Image(systemName: "tag").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(focused ? Color.tungsten : .textTertiary)
                    TextField(placeholder, text: $draft, prompt: Text(placeholder).foregroundStyle(Color.textTertiary))
                        .textFieldStyle(.plain)
                        .font(.ui(11.5, weight: .medium))
                        .foregroundStyle(.textPrimary)
                        .focused($focused)
                        .frame(width: 92)
                        .onSubmit(commit)
                        .onChange(of: draft) { _, d in if d.contains(",") { commit() } }
                }
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background {
                    Capsule().fill(Color.surfaceSunken)
                        .overlay(Capsule().strokeBorder(focused ? Color.tungsten.opacity(0.6) : Color.hairline,
                                                        style: StrokeStyle(lineWidth: 1, dash: focused ? [] : [2, 2])))
                }
                .onTapGesture { focused = true }
            }
            if !offered.isEmpty {
                FlowRow(spacing: 8, lineSpacing: 4) {
                    Text("Used before").textRole(.caption, color: .textTertiary).fixedSize()
                    ForEach(offered, id: \.self) { s in
                        Button {
                            withStageAnimation(Theme.Motion.quick) { tags.append(s) }
                        } label: {
                            Text("+ \(s)").font(.ui(11, weight: .medium)).foregroundStyle(.textSecondary)
                                .lineLimit(1).fixedSize()
                        }
                        .buttonStyle(.plain)
                        .help("Add “\(s)”")
                    }
                }
            }
        }
    }

    private func commit() {
        let parts = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        draft = ""
        for p in parts where !tags.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
            tags.append(p)
        }
    }
}

/// Left-to-right wrapping layout for chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Consent

/// The permission tick: a velvet-edged box that lights mint once ticked, with the statement beside it.
struct ConsentCheck: View {
    @Binding var isOn: Bool
    var statement: String
    var detail: String?

    /// The words Clone uses, shared with the import sheet so both ask the same thing.
    static func cloneStatement(voices: Int = 1) -> String {
        voices > 1 ? "I have the speakers' permission to clone these voices." : "I have the speaker's permission to clone this voice."
    }
    static let cloneDetail = "If it's your own voice, that's you. Encore keeps the date you confirmed with the voice."

    @State private var isHovered = false

    var body: some View {
        Button {
            withStageAnimation(Theme.Motion.quick) { isOn.toggle() }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? Color.mint.opacity(0.16) : Color.surfaceSunken)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isOn ? Color.mint : (isHovered ? Color.textSecondary : Color.textTertiary.opacity(0.8)), lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.mint)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 20, height: 20)
                .glow(.mint, radius: 6, intensity: isOn ? 0.45 : 0)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statement).textRole(.headline, color: isOn ? .textPrimary : .textPrimary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).textRole(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityRepresentation {
            Toggle(statement, isOn: $isOn)
        }
    }
}

// MARK: - Voice file type

extension UTType {
    /// `.encorevoice` (a zip archive of voices).
    static var encoreVoice: UTType {
        UTType(filenameExtension: VoiceLibrary.fileExtension, conformingTo: .zip) ?? .zip
    }
}

// MARK: - Casting in Studio

extension AppDependencies {
    /// Casts a library voice in Studio (switching Studio to a downloaded cloning model if its current one can't clone)
    /// and goes there. Returns a note for the user when no cloning model is on this Mac.
    @discardableResult
    func castInStudio(_ voiceID: UUID, preferredModel: ModelChoice? = nil) -> String? {
        let studio = screenModel("Studio") { StudioModel(deps: self) }
        let note = studio.cast(voiceID: voiceID, preferredModel: preferredModel)
        router.go(.studio)
        return note
    }
}

// MARK: - Hear it

/// "Hear the new voice": a short line spoken with a downloaded cloning model. Used after a voice is saved in Clone
/// or Design. The line goes through `EncoreService.speak` without a History record (`SpeechRequest.voiceTryout`);
/// the take's scratch file is deleted when the next line is spoken or the panel is reset.
@MainActor @Observable
final class VoiceTryout {
    let service: EncoreService
    let shelf: ModelShelf
    let runner: JobRunner

    private(set) var voice: Voice?
    var line = ""
    var choice: ModelChoice?
    private(set) var result: GenerationRecord?

    init(service: EncoreService, shelf: ModelShelf) {
        self.service = service
        self.shelf = shelf
        runner = JobRunner(runtime: service.runtime)
    }

    /// Cloning models on this Mac, best first for `voice`.
    func cloningModels(for voice: Voice? = nil) -> [ModelManifest] {
        let downloaded = shelf.manifests(for: .tts, requiring: .cloning).filter(shelf.isAnyVariantDownloaded)
        guard let voice else { return downloaded }
        return downloaded.sorted { rank($0, voice) > rank($1, voice) }
    }

    private func rank(_ m: ModelManifest, _ v: Voice) -> Int {
        var r = 0
        if m.id == v.sourceModelID { r += 8 }
        // Design-then-clone: Qwen3-TTS VoiceDesign voices are meant for Qwen3-TTS Base.
        if v.sourceModelID?.hasPrefix("qwen3-tts") == true, m.id == "qwen3-tts-base" { r += 6 }
        if !v.transcript.isEmpty, m.capabilities.cloningUsesTranscript { r += 2 }
        if let l = v.language, VoiceLanguages.modelCode(for: l, in: m) != nil { r += 1 }
        return r
    }

    /// Readies the panel for a newly saved voice: picks a model and writes a line.
    func prepare(for voice: Voice, preferredModel: ModelChoice? = nil) {
        self.voice = voice
        discardResult()
        runner.error = nil
        let models = cloningModels(for: voice)
        if let p = preferredModel, models.contains(where: { $0.id == p.modelID }) {
            choice = p
        } else if let m = models.first {
            choice = ModelChoice(modelID: m.id, variantID: shelf.preferredVariant(m).id)
        } else {
            choice = nil
        }
        line = "Hello, I'm \(voice.name). This is the first thing I've ever said, and I'd love to say a great deal more."
    }

    func reset() {
        runner.cancel()
        voice = nil
        discardResult()
        runner.error = nil
    }

    var manifest: ModelManifest? { choice.flatMap { service.catalog.model($0.modelID) } }

    var blockedReason: String? {
        guard voice != nil else { return "Save the voice first." }
        guard let m = manifest else { return "Download a cloning model to hear it." }
        if shelf.hasScanned, !shelf.isDownloaded(m, variantID: choice?.variantID) { return "\(m.name) isn't downloaded yet." }
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a line for it to say." }
        return nil
    }

    func speak() {
        guard blockedReason == nil, let voice, let m = manifest else { return }
        let request = SpeechRequest.voiceTryout(voice, modelID: m.id, variantID: shelf.preferredVariant(m, requested: choice?.variantID).id,
                                                text: line, language: VoiceLanguages.modelCode(for: voice.language, in: m))
        let service = self.service
        discardResult()
        runner.start(.speech, model: m, variantID: request.variantID) {
            service.speak(request)
        } onEvent: { [weak self] event in
            if case .finished(let record) = event { withStageAnimation { self?.result = record } }
        }
    }

    /// Hides the take and deletes its file: try-outs aren't in History, so their scratch files are ours to remove.
    private func discardResult() {
        if let url = result?.audioURL,
           url.deletingLastPathComponent().standardizedFileURL == service.unsavedDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        result = nil
    }

    #if DEBUG
    func debugShow(voice: Voice, choice: ModelChoice?, result: GenerationRecord?) {
        self.voice = voice
        self.choice = choice
        self.result = result
        if line.isEmpty { line = "Hello, I'm \(voice.name). This is the first thing I've ever said, and I'd love to say a great deal more." }
    }
    #endif
}

/// The panel for `VoiceTryout`: the line, the cloning model, Speak, the result, and where to go next.
struct VoiceTryoutPanel: View {
    @Bindable var tryout: VoiceTryout
    var onAnother: (() -> Void)?
    var anotherTitle = "Make another"

    @Environment(AppDependencies.self) private var deps
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hear it").textRole(.eyebrow)
                Spacer()
                if let m = tryout.manifest {
                    Text("performed by \(m.name)").textRole(.caption, color: .textTertiary)
                }
            }
            StageTextField("A line for the new voice", text: $tryout.line, symbol: "text.quote", onSubmit: tryout.speak)
            if tryout.cloningModels().isEmpty {
                Banner(.warning, title: "No cloning model on this Mac",
                       message: "A voice is performed by a model that clones, such as Qwen3-TTS Base or Chatterbox Turbo. Download one to hear it.") {
                    Button("Open Models") { deps.router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
                }
            } else {
                ModelPicker(task: .tts, requires: .cloning, feature: .cloning, selection: $tryout.choice)
            }
            RunSurface(runner: tryout.runner, title: "Speak", systemImage: "waveform",
                       blockedReason: tryout.runner.error == nil ? tryout.blockedReason : nil, action: tryout.speak)
            if let error = tryout.runner.error {
                ServiceErrorBanner(error: error, onDismiss: { tryout.runner.error = nil }, onRetry: tryout.speak)
            }
            if let record = tryout.result {
                WaveformPlayer(url: record.audioURL, title: record.title,
                               subtitle: "\(record.modelName) · made in \(RunSurface.seconds(record.elapsed)) · not saved")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            PerforatedDivider().padding(.vertical, Theme.Space.xxs)
            FlowRow(spacing: Theme.Space.s, lineSpacing: Theme.Space.s) { followOns }
        }
    }

    @ViewBuilder private var followOns: some View {
        if let voice = tryout.voice {
            Button("Use in Studio", systemImage: "text.bubble") {
                if let note = deps.castInStudio(voice.id, preferredModel: tryout.choice) { toasts.show(note, tone: .warning) }
                else { toasts.show("\(voice.name) is cast in Studio", tone: .success, symbol: "person.wave.2") }
            }
            .buttonStyle(.primary)
            Button("Open in Voices", systemImage: "person.wave.2") {
                deps.screenModel("Voices") { VoicesModel(deps: deps) }.focus(voice.id)
                deps.router.go(.voices)
            }
            .buttonStyle(.secondary)
            if let onAnother {
                Button(anotherTitle, systemImage: "arrow.counterclockwise", action: onAnother).buttonStyle(.ghost)
            }
        }
    }
}
