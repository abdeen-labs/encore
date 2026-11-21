import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Voice cloning: one guided flow from a recording to a saved voice, laid out as a cue sheet —
/// Q1 source, Q2 trim, Q3 the words, Q4 credits, Q5 consent — and then the voice's first words.
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
    @Environment(Router.self) private var router
    @State private var width: CGFloat = 900
    @State private var choosingSource = false

    private var wide: Bool { width >= 800 }

    var body: some View {
        ScreenScaffold(.clone) {
            CueSheet(step: model.currentStep, hasSource: model.source != nil)
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
        } actions: {
            if model.source != nil, model.saved == nil {
                Button("Use another recording…", systemImage: "arrow.triangle.2.circlepath") { choosingSource = true }
                    .buttonStyle(.ghost)
            }
            if model.source != nil || model.saved != nil {
                Button(model.saved == nil ? "Start over" : "Clone another", systemImage: "arrow.counterclockwise") {
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

    // MARK: Workbench

    @ViewBuilder private var workbench: some View {
        if wide {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    trimSection
                    TranscriptWell(model: model)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    CreditsCard(model: model)
                    ConsentAndSave(model: model)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 318)
            }
        } else {
            trimSection
            TranscriptWell(model: model)
            CreditsCard(model: model)
            ConsentAndSave(model: model)
        }
    }

    @ViewBuilder private var trimSection: some View {
        if let source = model.source {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CueLabel(number: 2, title: "Trim to the best stretch", detail: trimDetail(source))
                trimmer(source)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await model.load(url) }
                return true
            }
        }
    }

    private func trimDetail(_ source: CloneModel.Source) -> String {
        let keep = "keep \(Int(model.target.lowerBound))–\(Int(model.target.upperBound)) seconds of one voice, clean, no music."
        if source.kind == .recording { return "Your recording. Now " + keep }
        let lead = source.duration > 60 ? "A long file is fine — " : "Any length is fine — "
        return lead + keep + (source.hasVideo ? " Only the video's sound is used." : "")
    }

    private func trimmer(_ source: CloneModel.Source) -> some View {
        WaveformTrimmer(url: source.url, selection: model.trimmerSelection, target: model.target, title: source.name,
                        suggestsSelection: !model.hasChosenSelection)
    }
}

// MARK: - Cue sheet

/// The flow at a glance: five numbered cues, done ones ticked, the current one lit.
private struct CueSheet: View {
    let step: Int
    let hasSource: Bool

    private static let cues = ["Source", "Trim", "Words", "Credits", "Consent"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.cues.enumerated()), id: \.offset) { i, title in
                let done = i < step || step == 5
                let current = i == step || (step == 4 && i >= 2 && i <= 4 && hasSource && !done)
                HStack(spacing: 7) {
                    ZStack {
                        Circle().fill(done ? Color.mint.opacity(0.14) : (current ? Color.tungsten.opacity(0.16) : Color.surfaceSunken))
                        Circle().strokeBorder(done ? Color.mint.opacity(0.6) : (current ? Color.tungsten : Color.hairlineStrong), lineWidth: 1)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Color.mint)
                        } else {
                            Text("Q\(i + 1)").font(.mono(8.5, weight: .semibold))
                                .foregroundStyle(current ? Color.tungsten : .textTertiary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .glow(current ? .tungsten : .clear, radius: 6, intensity: 0.35)
                    Text(title)
                        .font(.ui(12, weight: current ? .semibold : .medium))
                        .foregroundStyle(current ? Color.textPrimary : (done ? .textSecondary : .textTertiary))
                        .lineLimit(1)
                        .fixedSize()
                }
                if i < Self.cues.count - 1 {
                    Rectangle()
                        .fill(i < step ? Color.mint.opacity(0.35) : Color.hairlineStrong)
                        .frame(height: 1)
                        .frame(minWidth: 10, maxWidth: .infinity)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(min(step, 4) + 1) of 5")
    }
}

/// "Q2 · Trim to the best stretch" above a section, with one line of guidance.
struct CueLabel: View {
    let number: Int
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Q\(number)").font(.mono(11, weight: .semibold)).foregroundStyle(Color.tungsten.opacity(0.85))
                Text(title).textRole(.heading)
            }
            if let detail { Text(detail).textRole(.caption).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: - Q1 Source

private struct SourceStage: View {
    @Bindable var model: CloneModel
    let wide: Bool
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            CueLabel(number: 1, title: "Bring in the voice",
                     detail: model.mode == .record
                        ? "Record the speaker reading a few natural sentences. Go longer if you like; you'll pick the best few seconds next."
                        : "Drop any recording or video of the speaker — an interview, a voice memo, a whole podcast. Length doesn't matter; you'll pick the best few seconds next.")
            if model.mode == .record {
                recordPanel
            } else {
                DropZone(symbol: "waveform.badge.plus", title: "Drop a recording of the voice",
                         message: "Audio or video, any length · WAV, MP3, M4A, FLAC, MOV, MP4…",
                         allowedTypes: CloneMedia.types, minHeight: wide ? 210 : 170) { urls in
                    if let url = urls.first { Task { await model.load(url) } }
                }
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
            Hints(wide: wide)
            if model.isPrepared, model.tryout.cloningModels().isEmpty {
                Banner(.neutral, title: "No cloning model on this Mac yet",
                       message: "You can make and save the voice now. To hear it speak, download a model that clones, such as Qwen3-TTS Base or Chatterbox Turbo.") {
                    Button("Open Models") { deps.router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
                }
            }
        }
    }

    private var recordInstead: some View {
        Button {
            withStageAnimation { model.mode = .record }
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.velvet)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.velvet.opacity(0.12)))
                    .overlay(Circle().strokeBorder(Color.velvet.opacity(0.4), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Or record it now").textRole(.headline)
                    Text("Use this Mac's microphone. Read a few natural sentences; longer takes are fine.").textRole(.caption)
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

/// Three short notes on what makes a good reference.
private struct Hints: View {
    let wide: Bool

    var body: some View {
        let items: [(String, String, String)] = [
            ("person.wave.2", "One voice", "No music, no second speaker, little room echo."),
            ("timer", "A few seconds", "5–15 s of natural speech clones best. You choose the stretch."),
            ("checkmark.shield", "Their permission", "Clone only voices you have the speaker's consent to use."),
        ]
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.m))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
        layout {
            ForEach(items, id: \.1) { symbol, title, text in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.tungsten.opacity(0.8))
                        .frame(width: 18).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).textRole(.label)
                        Text(text).textRole(.caption, color: .textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, Theme.Space.xs)
    }
}

// MARK: - Q3 Transcript

private struct TranscriptWell: View {
    @Bindable var model: CloneModel
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CueLabel(number: 3, title: "The words", detail: detail)
            ZStack(alignment: .topTrailing) {
                ScriptEditor(text: $model.transcript, placeholder: placeholder, minHeight: 92, showsStats: false)
                    .opacity(isWorking && model.transcript.isEmpty ? 0.55 : 1)
                if isWorking {
                    HStack(spacing: 6) {
                        ActivityIndicator(size: 12)
                        Text(workingText).font(.ui(11, weight: .medium)).foregroundStyle(Color.tungsten)
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(Color.surfaceRaised).overlay(Capsule().strokeBorder(Color.tungsten.opacity(0.3))))
                    .padding(8)
                    .transition(.opacity)
                }
            }
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

    private var workingText: String {
        if case .transcribing(let r) = model.transcriptState {
            return "Transcribing \(Timecode.string(r.lowerBound))–\(Timecode.string(r.upperBound))…"
        }
        return "Transcribing…"
    }

    private var placeholder: String {
        switch model.transcriptState {
        case .pending, .transcribing: "Listening to the clip…"
        default: "Type exactly what's said in the clip…"
        }
    }

    private var detail: String {
        let m = model.modelManifest
        if m?.reference?.transcript == .unused {
            return "Exactly what's said in the clip. \(m!.name) doesn't need it, but it's kept with the voice for models that do."
        }
        return "Exactly what's said in the clip, so the model can read along. Transcribed on this Mac; fix anything it misheard."
    }

    @ViewBuilder private var status: some View {
        switch model.transcriptState {
        case .ready(_, let name):
            statusLine("checkmark.circle.fill", .mint, "Transcribed on this Mac by \(name).")
        case .stale:
            HStack(spacing: Theme.Space.s) {
                statusLine("exclamationmark.triangle.fill", .footlight, "The selection moved after you edited this.")
                Spacer(minLength: 0)
                Button("Transcribe again", systemImage: "arrow.clockwise", action: model.retranscribe)
                    .buttonStyle(.secondary).controlSize(.small)
            }
        case .noModel:
            Banner(.warning, title: "No transcription model on this Mac",
                   message: "Type what's said in the clip, or download Whisper or Parakeet to fill it in automatically.") {
                Button("Get one in Models") { router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
            }
        case .failed(let message):
            Banner(.danger, title: "Couldn't transcribe the clip", message: message) {
                Button("Try again", action: model.retranscribe).buttonStyle(.secondary).controlSize(.small)
            }
        case .idle where model.lengthVerdict == .tooLong:
            statusLine("scissors", .textTertiary, "Trim the clip and it's transcribed automatically.")
        default:
            EmptyView()
        }
    }

    private func statusLine(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            Text(text).textRole(.caption).lineLimit(2)
        }
    }
}

// MARK: - Q4 Credits

private struct CreditsCard: View {
    @Bindable var model: CloneModel
    @Environment(VoiceLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CueLabel(number: 4, title: "Credits")
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").textRole(.label, color: .textSecondary)
                TextField(model.suggestedName, text: $model.name, prompt: Text(model.suggestedName).foregroundStyle(Color.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.display(21))
                    .foregroundStyle(.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .surface(.sunken, radius: Theme.Radius.s)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").textRole(.label, color: .textSecondary)
                TagEditor(tags: $model.tags, suggestions: library.allTags)
            }
            VoiceLanguageMenu(language: $model.language)
            VStack(alignment: .leading, spacing: 6) {
                Text("Made for").textRole(.label, color: .textSecondary)
                ModelPicker(task: .tts, requires: .cloning, feature: .cloning, selection: $model.modelChoice, panelWidth: 400)
                Text(madeForCaption).textRole(.caption, color: .textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            AdvancedDisclosure("Notes") {
                ScriptEditor(text: $model.notes, placeholder: "Where it's from, how to direct it…", minHeight: 60, showsStats: false)
            }
        }
        .padding(Theme.Space.l)
        .surface(.card)
    }

    private var madeForCaption: String {
        if let m = model.modelManifest, let r = m.reference {
            return "\(m.name) likes \(Int(r.minSeconds))–\(Int(r.maxSeconds)) s of reference. Any cloning model can use the voice later."
        }
        return "The voice works with any model that clones."
    }
}

// MARK: - Q5 Consent and save

private struct ConsentAndSave: View {
    @Bindable var model: CloneModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CueLabel(number: 5, title: "Consent")
            ConsentCheck(isOn: $model.consent,
                         statement: "I have the speaker's permission to clone this voice.",
                         detail: "If it's your own voice, that's you. Encore keeps the date you confirmed with the voice.")
            PerforatedDivider(bleed: Theme.Space.l)
            HStack(spacing: Theme.Space.m) {
                Button(model.isSaving ? "Saving…" : "Save voice", systemImage: "person.crop.circle.badge.plus") {
                    Task { await model.save() }
                }
                .buttonStyle(.primary)
                .controlSize(.large)
                .disabled(model.blockedReason != nil)
                .keyboardShortcut(.return, modifiers: .command)
                VStack(alignment: .leading, spacing: 2) {
                    if let reason = model.blockedReason {
                        Text(reason).textRole(.caption, color: .textSecondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("\(Timecode.string(model.length)) of \(model.source?.name ?? "the recording") will be kept.")
                            .textRole(.caption).fixedSize(horizontal: false, vertical: true)
                        if model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No transcript: models that read along will clone less closely.")
                                .textRole(.caption, color: .footlight).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let error = model.saveError {
                Banner(.danger, title: "The voice wasn't saved", message: error, onDismiss: { model.saveError = nil })
            }
        }
        .padding(Theme.Space.l)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            shape.fill(Color.surface)
                .overlay(shape.fill(LinearGradient(colors: [(model.consent ? Color.mint : .velvet).opacity(0.07), .clear],
                                                   startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder((model.consent ? Color.mint : Color.velvet).opacity(0.22), lineWidth: 1))
        }
        .stageAnimation(Theme.Motion.standard, value: model.consent)
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
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.l))
        layout {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.mint).glow(.mint, radius: 6, intensity: 0.4)
                    Text("Joined the company").textRole(.eyebrow, color: .mint)
                }
                Text(voice.name).font(.display(34)).foregroundStyle(.textPrimary).lineLimit(2)
                if !voice.tags.isEmpty {
                    FlowRow { ForEach(voice.tags, id: \.self) { Chip($0) } }
                }
                if let url = library.referenceAudioURL(for: voice.id) {
                    WaveformPlayer(url: url, title: "Reference clip", subtitle: Self.facts(voice))
                }
                if !voice.transcript.isEmpty {
                    Text("“\(voice.transcript)”")
                        .font(.display(15, italic: true)).foregroundStyle(.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let at = voice.consentConfirmedAt {
                    Label("Speaker's permission confirmed \(at.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.shield")
                        .textRole(.caption, color: .textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VoiceTryoutPanel(tryout: model.tryout)
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
