import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Voice cloning: one form from a recording to a saved voice. First the source (a dropped file or a
/// recording), then the trimmer, the words, the voice's name and tags, and a pinned save bar with the
/// consent check. After saving, the voice's first words.
struct CloneScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Clone") { CloneModel(deps: deps) }
        CloneStage(model: model)
    }
}

/// Media the source step accepts: any audio or video (mkv/webm need ffmpeg, which `AudioReader` finds itself).
enum CloneMedia {
    static let types: [UTType] = [.audio, .audiovisualContent, .movie]
        + ["mkv", "webm", "opus", "ogg", "flac"].compactMap { UTType(filenameExtension: $0) }
}

struct CloneStage: View {
    @Bindable var model: CloneModel
    @Environment(\.scaffoldScrolls) private var scrolls
    @State private var width: CGFloat = 880
    @State private var choosingSource = false

    /// Two columns from here up; below it (the minimum window) they stack.
    private var wide: Bool { width >= 760 }
    private var isWorking: Bool { model.source != nil && model.saved == nil }

    var body: some View {
        ScreenScaffold(.clone, scrolls: false) {
            VStack(alignment: .leading, spacing: 0) {
                scrolling {
                    Group {
                        if let saved = model.saved {
                            SavedStage(model: model, voice: saved, wide: wide)
                        } else if model.source == nil {
                            SourceStage(model: model, wide: wide)
                        } else {
                            workbench
                        }
                    }
                    .transition(.opacity)
                }
                if isWorking {
                    SaveBar(model: model, wide: wide)
                }
            }
        } actions: {
            if isWorking {
                Button("Use another recording…", systemImage: "arrow.triangle.2.circlepath") { choosingSource = true }
                    .buttonStyle(.ghost)
                Button("Start over", systemImage: "arrow.counterclockwise") {
                    withStageAnimation { model.startOver() }
                }
                .buttonStyle(.ghost)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Theme.Space.screenInset } action: { width = $0 }
        .task { await model.prepare() }
        .fileImporter(isPresented: $choosingSource, allowedContentTypes: CloneMedia.types) { result in
            if case .success(let url) = result { Task { await model.load(url) } }
        }
        .stageAnimation(Theme.Motion.standard, value: model.source?.url)
        .stageAnimation(Theme.Motion.entrance, value: model.saved?.id)
    }

    /// The form scrolls above the pinned save bar. Full-height snapshots (`scaffoldScrolls == false`) lay it out whole.
    @ViewBuilder private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if scrolls {
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, Theme.Space.l)
            }
            .scrollIndicators(.automatic)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, Theme.Space.l)
        }
    }

    // MARK: Workbench

    @ViewBuilder private var workbench: some View {
        if wide {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    trimSection
                    TranscriptSection(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                DetailsSection(model: model)
                    .frame(width: 318)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                trimSection
                TranscriptSection(model: model)
                DetailsSection(model: model)
            }
        }
    }

    @ViewBuilder private var trimSection: some View {
        if let source = model.source {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Trim to the best stretch", subtitle: trimCaption(source))
                WaveformTrimmer(url: source.url, selection: model.trimmerSelection, target: model.target, title: source.name,
                                suggestsSelection: !model.hasChosenSelection, wholeFileRange: model.wholeFileRange)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await model.load(url) }
                return true
            }
        }
    }

    /// One line; the trimmer itself says whether the length is right.
    private func trimCaption(_ source: CloneModel.Source) -> String {
        if source.hasVideo { return "Only the selection is kept, and only the video's sound." }
        return source.kind == .recording ? "Only the selection of your recording is kept." : "Only the selection is kept, so a long file is fine."
    }
}

// MARK: - Source

private struct SourceStage: View {
    @Bindable var model: CloneModel
    let wide: Bool
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if model.mode == .record {
                recordPanel
            } else {
                DropZone(symbol: "waveform.badge.plus", title: "Drop a recording of the voice",
                         message: "Audio or video of any length",
                         allowedTypes: CloneMedia.types, minHeight: wide ? 220 : 170) { urls in
                    if let url = urls.first { Task { await model.load(url) } }
                }
                .help("WAV, MP3, M4A, FLAC, MOV, MP4 and more")
                .overlay {
                    if model.isLoadingSource {
                        RoundedRectangle(cornerRadius: Theme.Radius.l).fill(Color.backdrop.opacity(0.7))
                            .overlay { HStack(spacing: Theme.Space.s) { ActivityIndicator(); Text("Reading the file…").textRole(.label) } }
                    }
                }
                recordInstead
            }
            if let error = model.sourceError {
                Banner(.danger, title: "That file didn't open", message: error, onDismiss: { model.sourceError = nil })
            }
            Text(guidance).textRole(.caption).fixedSize(horizontal: false, vertical: true)
            if model.isPrepared, model.tryout.cloningModels().isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text("No cloning model on this Mac yet. You can save the voice now and hear it once you have one.")
                        .textRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Models") { deps.router.go(.models) }
                        .buttonStyle(.ghost)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Models that clone include Qwen3-TTS Base and Chatterbox Turbo.")
                }
            }
        }
    }

    private var guidance: String {
        let lo = Int(model.target.lowerBound), hi = Int(model.target.upperBound)
        if model.mode == .record {
            return "Read a few natural sentences; longer is fine, you'll keep the best \(lo) to \(hi) seconds. Only record with the speaker's permission."
        }
        return "One voice, \(lo) to \(hi) seconds of natural speech (you'll pick the stretch next), and only with the speaker's permission."
    }

    private var recordInstead: some View {
        Button {
            withStageAnimation { model.mode = .record }
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "mic")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.surfaceRaised))
                    .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Or record it now").textRole(.headline)
                    Text("Use this Mac's microphone.").textRole(.caption)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.textTertiary)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .surface(.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The recorder only opens the microphone when its Record button is pressed; showing it never does.
    @ViewBuilder private var recordPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            #if DEBUG
            if let display = CloneFixtureState.recording {
                RecordingPanel(state: display, target: model.target, onRecord: {}, onStop: {})
            } else {
                RecorderView(recorder: model.liveRecorder(), target: model.target) { model.recordingFinished($0) }
            }
            #else
            RecorderView(recorder: model.liveRecorder(), target: model.target) { model.recordingFinished($0) }
            #endif
            Button("Use a file instead", systemImage: "arrow.left") { withStageAnimation { model.mode = .file } }
                .buttonStyle(.ghost)
                .controlSize(.small)
        }
    }
}

// MARK: - Transcript

private struct TranscriptSection: View {
    @Bindable var model: CloneModel
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("What's said in the clip", subtitle: caption)
            ScriptEditor(text: $model.transcript, placeholder: "Type exactly what's said in the clip…", minHeight: 92, showsStats: false)
                .opacity(isWorking && model.transcript.isEmpty ? 0.55 : 1)
            status
        }
        .stageAnimation(Theme.Motion.quick, value: isWorking)
    }

    private var isWorking: Bool {
        switch model.transcriptState {
        case .pending, .transcribing: true
        default: false
        }
    }

    private var caption: String {
        if let m = model.modelManifest, m.reference?.transcript == .unused {
            return "\(m.name) doesn't need it, but it's kept for models that do."
        }
        return "So the model can read along. Fix anything it misheard."
    }

    @ViewBuilder private var status: some View {
        switch model.transcriptState {
        case .pending, .transcribing:
            HStack(spacing: 6) {
                ActivityIndicator(tone: .neutral, size: 12)
                Text("Transcribing the selection on this Mac…").textRole(.caption)
            }
            .transition(.opacity)
        case .ready(_, let name):
            if model.hasTranscript {
                statusLine("checkmark.circle.fill", .matcha, "Transcribed on this Mac.")
                    .help("Transcribed by \(name)")
            } else {
                noTranscript
            }
        case .stale:
            HStack(spacing: Theme.Space.s) {
                statusLine("exclamationmark.triangle.fill", .honey, "The selection moved after you edited this.")
                Spacer(minLength: 0)
                Button("Transcribe again", systemImage: "arrow.clockwise", action: model.retranscribe)
                    .buttonStyle(.secondary).controlSize(.small)
            }
        case .noModel:
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                statusLine("exclamationmark.triangle.fill", .honey, "No transcription model on this Mac. Type it, or get one to fill it in.")
                Spacer(minLength: 0)
                Button("Open Models") { router.go(.models) }
                    .buttonStyle(.ghost).controlSize(.small).fixedSize()
                    .help("Whisper and Parakeet transcribe on this Mac.")
            }
        case .failed(let message):
            Banner(.danger, title: "Couldn't transcribe the clip", message: message) {
                Button("Try again", action: model.retranscribe).buttonStyle(.secondary).controlSize(.small)
            }
        case .idle where model.lengthVerdict == .tooLong:
            statusLine("scissors", .textTertiary, "Trim the clip and it's transcribed automatically.")
        case .idle where !model.hasTranscript && model.lengthVerdict != .tooShort:
            noTranscript
        default:
            EmptyView()
        }
    }

    private var noTranscript: some View {
        statusLine("exclamationmark.triangle.fill", .honey, "No transcript yet: models that read along will clone less closely.")
    }

    private func statusLine(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            Text(text).textRole(.caption).lineLimit(2)
        }
    }
}

// MARK: - Name and tags

private struct DetailsSection: View {
    @Bindable var model: CloneModel
    @Environment(VoiceLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Name and tags", subtitle: "How the voice is listed in Voices.")
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                field("Name") {
                    TextField(model.suggestedName, text: $model.name, prompt: Text(model.suggestedName).foregroundStyle(Color.textTertiary))
                        .textFieldStyle(.plain)
                        .textRole(.heading)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .surface(.sunken, radius: Theme.Radius.s)
                }
                field("Tags") {
                    TagEditor(tags: $model.tags, suggestions: library.allTags)
                }
                VoiceLanguageMenu(language: $model.language)
                field("Made for") {
                    ModelPicker(task: .tts, requires: .cloning, feature: .cloning, selection: $model.modelChoice, panelWidth: 400)
                    Text("Sets the length to aim for. Any cloning model can use the voice later.")
                        .textRole(.caption, color: .textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(madeForHelp)
                }
                AdvancedDisclosure("Notes") {
                    ScriptEditor(text: $model.notes, placeholder: "Where it's from, how to direct it…", minHeight: 60, showsStats: false)
                }
            }
            .padding(Theme.Space.l)
            .surface(.card)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).textRole(.label, color: .textSecondary)
            content()
        }
    }

    private var madeForHelp: String {
        if let m = model.modelManifest, let r = m.reference {
            return "\(m.name) works best with \(Int(r.minSeconds)) to \(Int(r.maxSeconds)) seconds of reference."
        }
        return "The voice works with any model that clones."
    }
}

// MARK: - Save bar

/// Pinned below the scrolling form: the consent check, what will be kept, and Save.
private struct SaveBar: View {
    @Bindable var model: CloneModel
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Hairline()
            if let error = model.saveError {
                Banner(.danger, title: "The voice wasn't saved", message: error, onDismiss: { model.saveError = nil })
            }
            if wide {
                HStack(alignment: .center, spacing: Theme.Space.xl) {
                    ConsentCheck(isOn: $model.consent, statement: ConsentCheck.cloneStatement(), detail: ConsentCheck.cloneDetail)
                    note
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240, alignment: .trailing)
                    saveButton
                }
            } else {
                ConsentCheck(isOn: $model.consent, statement: ConsentCheck.cloneStatement(), detail: nil)
                    .help(ConsentCheck.cloneDetail)
                HStack(spacing: Theme.Space.m) {
                    note.frame(maxWidth: .infinity, alignment: .leading)
                    saveButton
                }
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// What will be kept, or what still stands in the way (the consent check asks for the tick itself).
    private var note: some View {
        Group {
            if let reason = model.blockedReasonBesidesConsent {
                Text(reason).textRole(.caption)
            } else {
                Text("Keeps \(CloneModel.seconds(model.length)) of \(model.source?.name ?? "the recording").")
                    .textRole(.caption)
                    .truncationMode(.middle)
            }
        }
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var saveButton: some View {
        Button(model.isSaving ? "Saving…" : "Save voice", systemImage: "person.crop.circle.badge.plus") {
            Task { await model.save() }
        }
        .buttonStyle(.primary)
        .controlSize(.large)
        .fixedSize()
        .disabled(model.blockedReason != nil)
        .keyboardShortcut(.return, modifiers: .command)
    }
}

// MARK: - Saved

private struct SavedStage: View {
    @Bindable var model: CloneModel
    let voice: Voice
    let wide: Bool
    @Environment(VoiceLibrary.self) private var library

    var body: some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.xl))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xl))
        layout {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                StatusBadge("Saved to Voices", tone: .success)
                Text(voice.name).textRole(.title).lineLimit(2)
                if !voice.tags.isEmpty {
                    FlowRow { ForEach(voice.tags, id: \.self) { Chip($0) } }
                }
                if let url = library.referenceAudioURL(for: voice.id) {
                    WaveformPlayer(url: url, title: "Reference clip", subtitle: Self.facts(voice))
                }
                if !voice.transcript.isEmpty {
                    Text("“\(voice.transcript)”")
                        .textRole(.body, color: .textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let at = voice.consentConfirmedAt {
                    Label("Speaker's permission confirmed \(at.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.shield")
                        .textRole(.caption, color: .textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VoiceTryoutPanel(tryout: model.tryout, onAnother: { withStageAnimation { model.startOver() } }, anotherTitle: "Clone another")
                .padding(Theme.Space.l)
                .surface(.card)
                .frame(maxWidth: wide ? 420 : .infinity)
        }
    }

    static func facts(_ v: Voice) -> String {
        var parts = [String(format: "%.1f s", v.duration)]
        if let l = v.language { parts.append(VoiceLanguages.name(l)) }
        parts.append("cloned \(v.createdAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
/// Fixture-only override (set by `VoiceFixtures`): a recording panel drawn from fake state, so snapshots never
/// create an `AudioRecorder` or touch the microphone.
enum CloneFixtureState {
    static var recording: RecordingDisplay?
}
#endif
