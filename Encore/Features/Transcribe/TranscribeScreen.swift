import EncoreCore
import SwiftUI

/// Speech to text from any audio or video, with or without timings.
///
/// Setup is one line of decisions (model, language, how finely to time it) under the media. The result reads
/// like a script: timed rows you can click to hear, the playing one lit (word by word when the model timed
/// words), or plain prose; flip between them without re-running. Earlier transcriptions sit in the wings.
struct TranscribeScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Transcribe") { TranscribeModel(deps: deps) }
        TranscribeStage(model: model)
    }
}

struct TranscribeStage: View {
    @Bindable var model: TranscribeModel
    @Environment(Router.self) private var router
    @State private var width: CGFloat = 900
    @State private var showEarlier = false

    private var wide: Bool { width >= 860 }

    var body: some View {
        ScreenScaffold(.transcribe, scrolls: false) {
            content
        } actions: {
            headerActions
        }
        .task { await model.prepare() }
        .task(id: runtimeKey) {
            // Word timings may need the Python helper; segment timings prefer it when it gives finer rows.
            if model.timestamps == .word, let m = model.manifest { await model.shelf.refreshRuntimes(for: [m], requiring: model.requirement) }
            await model.refreshSegmentRuntime()
        }
        #if DEBUG
        .environment(\.inlinePickerPanels, TranscribeFixtures.isRequested)
        #endif
    }

    /// Re-asks which runtime will run the job when the model or the timings change.
    private var runtimeKey: String { "\(model.choice?.modelID ?? "-")|\(model.timestamps.rawValue)|\(model.isDownloaded)" }

    @ViewBuilder private var headerActions: some View {
        if model.needsFirstModel {
            if model.recentTotal > 0 {
                Button("Earlier in History", systemImage: "clock.arrow.circlepath") { router.go(.history) }
                    .buttonStyle(.ghost)
            }
        } else if model.record != nil {
            Button("New transcription", systemImage: "plus") { withStageAnimation { model.closeTranscript() } }
                .buttonStyle(.secondary).controlSize(.small)
                .disabled(model.runner.isBusy)
        }
        if !wide, !model.needsFirstModel, model.recentTotal > 0 {
            Button { showEarlier.toggle() } label: {
                Label("Earlier · \(model.recentTotal)", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.ghost)
            .pickerPanel(isPresented: $showEarlier, width: 340) {
                EarlierList(model: model, compact: true) { showEarlier = false }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.shelf.hasScanned {
            Color.clear
        } else if model.needsFirstModel {
            FirstModelStage(symbol: "captions.bubble", title: "Nothing to listen with yet",
                            message: "Transcription runs on this Mac. Download a model to start: Whisper knows about a hundred languages, Parakeet is fast for European ones.",
                            starterIDs: ["whisper-large-v3-turbo", "parakeet-tdt-v3", "whisper-tiny"])
        } else {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                Group {
                    if let record = model.record {
                        TranscriptView(model: model, record: record)
                    } else {
                        SetupView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if wide, model.recentTotal > 0 {
                    EarlierList(model: model, compact: false)
                        .frame(width: 252)
                        .padding(.leading, Theme.Space.l)
                        .overlay(alignment: .leading) { Hairline(.vertical) }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }
}

// MARK: - Setup

private struct SetupView: View {
    @Bindable var model: TranscribeModel
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let source = model.source {
                    WaveformPlayer(track: source.track)
                        .accessory {
                            if let info = source.info {
                                Text(source.url.pathExtension.uppercased() + (info.hasVideo ? " video" : ""))
                                    .textRole(.caption, color: .textTertiary)
                            }
                            Button("Remove", systemImage: "xmark") { withStageAnimation { model.clearSource() } }
                                .buttonStyle(.icon).controlSize(.small).help("Remove")
                                .disabled(model.runner.isBusy)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let u = urls.first, !model.runner.isBusy else { return false }
                            model.setSource(u); return true
                        }
                    if let p = source.problem { Banner(.warning, title: "Can't use this file", message: p) }
                } else {
                    DropZone(symbol: "captions.bubble", title: "Drop audio or video to transcribe",
                             message: "Any length · WAV, MP3, M4A, MP4, MOV, MKV, WebM…",
                             allowedTypes: TranscribeModel.mediaTypes, minHeight: 168) { urls in
                        if let u = urls.first { withStageAnimation { model.setSource(u) } }
                    }
                }
                settings
                runtimeNote
                notices
                RunSurface(runner: model.runner, title: "Transcribe", systemImage: "text.quote",
                           blockedReason: model.runner.error == nil ? model.blockedReason : nil,
                           action: model.transcribe)
                if model.runner.isRunning { ListeningPlaceholder() }
            }
            .padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.automatic)
        .stageAnimation(Theme.Motion.standard, value: model.runner.error == nil)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { modelPicker.frame(minWidth: 200); languagePicker; timings }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) { modelPicker; languagePicker }
                    timings
                }
            }
            if let m = model.manifest, !m.parameters.isEmpty {
                AdvancedDisclosure("Tuning", isExpanded: $model.showTuning) {
                    ParameterPanel(manifest: m, values: $model.parameters).padding(.top, Theme.Space.xs)
                }
            }
        }
    }

    private var modelPicker: some View {
        ModelPicker(task: .stt, requires: model.requirement, feature: .transcription, selection: $model.choice)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var languagePicker: some View {
        if let m = model.manifest {
            LanguagePicker(manifest: m, selection: $model.language)
                .fixedSize(horizontal: true, vertical: false)
                .help("Automatic detects the language from the first seconds.")
        }
    }

    private var timings: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Timings").textRole(.eyebrow)
            SegmentedControl(selection: $model.timestamps, options: TimestampGranularity.allCases) { g in
                switch g {
                case .none: "None"
                case .segment: "Segments"
                case .word: "Words"
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// Timings may route to the Python helper, which is slower to start; say so before the run, in one line, with
    /// the where and why in the tooltip. A blocked runtime is the banner's to say.
    @ViewBuilder private var runtimeNote: some View {
        if let note = runtimeNoteText {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Color.textTertiary)
                Text(note.text)
                    .textRole(.caption, color: .textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.xs)
            .help(note.detail)
        }
    }

    private var runtimeNoteText: (text: String, detail: String)? {
        guard let m = model.manifest else { return nil }
        switch model.timestamps {
        case .word:
            switch model.plannedRuntime {
            case .runs(.python)?:
                return ("The first run with word timings takes a few seconds to start.",
                        "Word timings come from \(m.name) in Encore's Python helper, which starts on the first run.")
            case nil:
                return ("Checking how to time each word…", "Checking where \(m.name) can time each word.")
            case .runs?, .blocked?:
                return nil
            }
        case .segment:
            // Only worth a line when the job leaves the app's own process.
            guard case .runs(.python)? = model.segmentRuntime else { return nil }
            return ("The first run takes a few seconds to start.",
                    "Sentence-length segments come from \(m.name) in Encore's Python helper, which starts on the first run.")
        case .none:
            return nil
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = model.runner.error {
            ServiceErrorBanner(error: error, onDismiss: { withStageAnimation { model.runner.error = nil } }, onRetry: model.transcribe)
        } else if let m = model.manifest, model.shelf.hasScanned, !model.isDownloaded {
            Banner(.warning, title: "\(m.name) isn't downloaded yet",
                   message: "Get it in Models (\(Bytes.file(m.variant(model.choice?.variantID).downloadBytes))), or pick a model that's on this Mac.") {
                Button("Get it in Models") { router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
            }
        } else if case .blocked(let e)? = model.plannedRuntime, let p = ErrorPresentation(e) {
            ServiceErrorBanner(error: e)
                .id(p.title)
        }
    }
}

/// While transcribing: ghost lines where the transcript will appear.
private struct ListeningPlaceholder: View {
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: isSnapshotting)) { ctx in
            let t = isSnapshotting ? 0.4 : ctx.date.timeIntervalSinceReferenceDate
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<5, id: \.self) { i in
                    HStack(spacing: Theme.Space.m) {
                        Capsule().fill(Color.textTertiary.opacity(0.25)).frame(width: 40, height: 8)
                        Capsule()
                            .fill(Color.textSecondary.opacity(0.12 + 0.1 * (0.5 + 0.5 * sin(t * 2.4 - Double(i) * 0.7))))
                            .frame(maxWidth: [0.92, 0.78, 0.86, 0.64, 0.8][i] * 520, minHeight: 10, maxHeight: 10)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.sunken)
        }
        .accessibilityLabel("Transcribing")
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    @Bindable var model: TranscribeModel
    let record: TranscriptionRecord
    @Environment(ToastCenter.self) private var toasts
    @State private var showExport = Self.startsWithExportOpen

    #if DEBUG
    private static var startsWithExportOpen: Bool { TranscribeFixtures.openExport }
    #else
    private static let startsWithExportOpen = false
    #endif

    var body: some View {
        let t = record.transcript
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let track = model.recordTrack {
                PlayheadReader(track: track, segments: t.segments) { active in
                    WaveformPlayer(track: track, cues: cues(t, active: active), activeCue: active, onCueTap: { track.play(from: $0.start) })
                }
            } else {
                // Information, not a problem to act on: a caption, with the old path in the tooltip.
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Color.textTertiary)
                    Text("“\(record.sourceName)” isn't where it was, so it can't play. The transcript is all here.")
                        .textRole(.caption, color: .textSecondary).lineLimit(1)
                }
                .padding(.horizontal, Theme.Space.xs)
                .help(record.sourcePath)
            }
            toolbar(t)
            if model.hasCoarseSegments {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Color.textTertiary)
                    Text("\(record.modelName) timed this in long blocks.")
                        .textRole(.caption, color: .textSecondary).lineLimit(1)
                        .help("Word timings also give sentence-length segments.")
                    Spacer(minLength: Theme.Space.s)
                    if model.recordTrack != nil, model.manifest?.capabilities.wordTimestamps == true {
                        Button("Run again with words") { withStageAnimation { model.rerunWithWords() } }
                            .buttonStyle(.ghost).controlSize(.small)
                            .disabled(model.runner.isBusy)
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
            }
            if t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && t.segments.isEmpty {
                EmptyState(symbol: "waveform.slash", title: "No speech found",
                           message: "The model didn't hear any words. Check the audio, or try another model or language.")
                Spacer(minLength: 0)
            } else if model.showTimings && !t.segments.isEmpty {
                TimedTranscript(model: model, segments: t.segments)
            } else {
                ProseTranscript(transcript: t)
            }
        }
        .stageAnimation(Theme.Motion.standard, value: model.showTimings)
    }

    /// Segment marks under the waveform: neutral, with only the playing one lit.
    private func cues(_ t: Transcript, active: Int?) -> [TrackCue] {
        t.segments.enumerated().map { i, s in TrackCue(id: i, start: s.start, end: s.end, tint: i == active ? .tungsten : .textSecondary) }
    }

    private func toolbar(_ t: Transcript) -> some View {
        HStack(spacing: Theme.Space.m) {
            if !t.segments.isEmpty {
                SegmentedControl(selection: $model.showTimings, options: [true, false]) { $0 ? "Timed" : "Text" }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Show the transcript with or without its timings (nothing is re-run)")
            }
            facts(t)
                .layoutPriority(-1)
            Spacer(minLength: Theme.Space.s)
            Button("Copy", systemImage: "doc.on.doc") {
                model.copy()
                toasts.show(model.showTimings && !t.segments.isEmpty ? "Copied with timestamps" : "Transcript copied", symbol: "doc.on.doc")
            }
            .buttonStyle(.ghost).controlSize(.small)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button { showExport.toggle() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary).controlSize(.small)
        }
        // The panel hangs from the toolbar's right end, so it opens over the transcript, not off the edge.
        .overlay(alignment: .bottomTrailing) {
            Color.clear.frame(width: 360, height: 1)
                .pickerPanel(isPresented: $showExport, width: 360) {
                    ExportPanel(model: model) { format in
                        showExport = false
                        model.export(format) { result in
                            switch result {
                            case .success(let name): toasts.show("Saved “\(name)”", tone: .success)
                            case .failure(let e): toasts.show(e.localizedDescription, tone: .danger, duration: 6)
                            }
                        }
                    }
                }
                .offset(y: -40)
        }
        .zIndex(5)
    }

    /// "139 words · English". The rest (segments, word timings, model) is in the tooltip.
    private func facts(_ t: Transcript) -> some View {
        var parts: [String] = ["\(model.wordCount) words"]
        if let l = t.language { parts.append(model.languageName(l)) }
        var detail: [String] = []
        if !t.segments.isEmpty { detail.append("\(t.segments.count) segments" + (model.hasWordTimings ? ", timed to the word" : "")) }
        detail.append(record.modelName)
        return Text(parts.joined(separator: " · ")).textRole(.caption, color: .textTertiary).lineLimit(1)
            .help(detail.joined(separator: " · "))
    }
}

/// Re-renders its content as the playhead moves, with the index of the segment under it.
private struct PlayheadReader<Content: View>: View {
    let track: PlaybackTrack
    let segments: [Transcript.Segment]
    @ViewBuilder let content: (Int?) -> Content

    var body: some View {
        content(track.hasPosition ? TranscribeModel.segmentIndex(at: track.currentTime, in: segments) : nil)
    }
}

/// One row per segment: time, then text. Click to hear it; the playing row is lit (and its words, when timed).
private struct TimedTranscript: View {
    @Bindable var model: TranscribeModel
    let segments: [Transcript.Segment]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let track = model.recordTrack {
                    PlayheadReader(track: track, segments: segments) { active in
                        rows(active: active, time: track.currentTime)
                            .onChange(of: active) { _, a in
                                guard model.follow, let a, track.isPlaying else { return }
                                withStageAnimation { proxy.scrollTo(a, anchor: .center) }
                            }
                    }
                } else {
                    rows(active: nil, time: 0)
                }
            }
            .scrollIndicators(.automatic)
            .surface(.sunken)
        }
    }

    private func rows(active: Int?, time: TimeInterval) -> some View {
        let hours = (segments.last?.end ?? 0) >= 3600
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                SegmentRow(segment: s, hours: hours, isActive: i == active, time: i == active ? time : nil,
                           canPlay: model.recordTrack != nil) { model.seek(to: s) }
                    .id(i)
            }
        }
        .padding(.vertical, Theme.Space.s)
    }
}

private struct SegmentRow: View {
    let segment: Transcript.Segment
    let hours: Bool
    let isActive: Bool
    /// The playhead, only for the active row (so the others don't redraw as it moves).
    let time: TimeInterval?
    let canPlay: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(TranscriptFormatterClock.string(segment.start, hours: hours))
                    .textRole(.monoSmall, color: isActive ? .tungsten : (hovered ? .textSecondary : .textTertiary))
                    .frame(width: hours ? 62 : 44, alignment: .leading)
                // The words carry their own colors (AttributedString runs win over the role's color).
                Text(attributed)
                    .textRole(.script)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if hovered, canPlay {
                    Image(systemName: "play.fill").font(.system(size: 8.5)).foregroundStyle(Color.textSecondary)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 7)
            .background {
                if isActive {
                    Rectangle().fill(Color.tungsten.opacity(0.07))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.tungsten).frame(width: 2.5).padding(.vertical, 5)
                        }
                } else if hovered {
                    Rectangle().fill(Color.textPrimary.opacity(0.03))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .onHover { hovered = $0 }
        .help(canPlay ? "Play from \(TranscriptFormatterClock.string(segment.start, hours: hours))" : "")
    }

    /// The segment's words; on the active row, the ones already spoken are bright and the current one is lit.
    private var attributed: AttributedString {
        let base: Color = isActive ? .textPrimary : .textSecondary
        guard isActive, let time, let words = segment.words, !words.isEmpty else {
            var a = AttributedString(segment.text.trimmingCharacters(in: .whitespaces))
            a.foregroundColor = base
            return a
        }
        var out = AttributedString()
        for (i, w) in words.enumerated() {
            var piece = AttributedString((i == 0 ? "" : " ") + w.text.trimmingCharacters(in: .whitespaces))
            if time >= w.start && time < w.end + 0.05 {
                piece.foregroundColor = .tungsten
                piece.backgroundColor = Color.tungsten.opacity(0.14)
            } else {
                piece.foregroundColor = time >= w.end ? Color.textPrimary : Color.textSecondary
            }
            out += piece
        }
        return out
    }
}

/// The transcript as prose: paragraphs broken at long pauses, selectable.
private struct ProseTranscript: View {
    let transcript: Transcript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                    Text(p).textRole(.script)
                        .frame(maxWidth: 680, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .surface(.sunken)
    }

    private var paragraphs: [String] {
        let segs = transcript.segments
        guard !segs.isEmpty else { return [transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)] }
        var out: [String] = []
        var current: [String] = []
        var chars = 0
        for (i, s) in segs.enumerated() {
            current.append(s.text.trimmingCharacters(in: .whitespaces))
            chars += s.text.count
            let gap = i + 1 < segs.count ? segs[i + 1].start - s.end : 0
            if gap > 1.4 || chars > 600 {
                out.append(current.joined(separator: " ")); current = []; chars = 0
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }
}

/// `TranscriptFormatter.clock` is internal to EncoreCore; the same `mm:ss` / `h:mm:ss` here.
enum TranscriptFormatterClock {
    static func string(_ t: TimeInterval, hours: Bool) -> String {
        let total = Int(max(0, t).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return hours ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Every export format with a taste of what it writes.
private struct ExportPanel: View {
    let model: TranscribeModel
    let onPick: (TranscriptFormat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelHeading(title: "Export as")
            ForEach(formats) { f in
                PickerRow(isSelected: false, action: { onPick(f) }) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(f.label).textRole(.headline)
                            Spacer()
                            Text(".\(f.fileExtension)").textRole(.monoSmall, color: .textTertiary)
                        }
                        Text(preview(f)).textRole(.monoSmall, color: .textTertiary).lineLimit(1)
                    }
                }
            }
        }
        .padding(Theme.Space.s)
    }

    private var formats: [TranscriptFormat] {
        let timed = !(model.transcript?.segments.isEmpty ?? true)
        return TranscriptFormat.allCases.filter { timed || $0 == .text || $0 == .json }
    }

    private func preview(_ f: TranscriptFormat) -> String {
        let s = model.text(as: f)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        switch f {
        case .srt: return lines.prefix(3).joined(separator: "  ")
        case .vtt: return lines.dropFirst().prefix(2).joined(separator: "  ")
        case .json: return lines.prefix(3).joined(separator: " ").replacingOccurrences(of: "  ", with: "")
        default: return lines.first ?? ""
        }
    }
}

// MARK: - Earlier

/// Earlier transcriptions (history), newest first. Click one to show it here.
private struct EarlierList: View {
    let model: TranscribeModel
    var compact: Bool
    var onPick: (() -> Void)?
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Earlier").textRole(compact ? .eyebrow : .section)
                Text("\(model.recentTotal)").textRole(.monoSmall, color: .textTertiary)
                Spacer()
            }
            .padding(.horizontal, compact ? Theme.Space.s : 0)
            .padding(.top, compact ? Theme.Space.s : 0)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.recent) { item in
                        if let r = item.transcription { row(r, title: item.title) }
                    }
                    if model.recentTotal > model.recent.count {
                        Button("All \(model.recentTotal) in History", systemImage: "arrow.right") { router.go(.history) }
                            .buttonStyle(.ghost).controlSize(.small).padding(.top, Theme.Space.xs)
                    }
                }
                .padding(compact ? Theme.Space.s : 0)
            }
            .frame(maxHeight: compact ? 380 : .infinity)
            .fixedSize(horizontal: false, vertical: compact)
        }
    }

    private func row(_ r: TranscriptionRecord, title: String) -> some View {
        let shown = model.record?.id == r.id
        return PickerRow(isSelected: shown, action: {
            withStageAnimation { model.open(r) }
            onPick?()
        }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).textRole(.headline, color: shown ? .textPrimary : .textSecondary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(Timecode.string(r.transcript.duration ?? 0, tenths: false)).textRole(.monoSmall, color: .textTertiary)
                }
                Text(r.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)).textRole(.caption, color: .textTertiary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(r.createdAt, format: .relative(presentation: .named)).textRole(.caption, color: .textTertiary)
                    if r.transcript.segments.contains(where: { !($0.words ?? []).isEmpty }) {
                        Text("· word timings").textRole(.caption, color: .textTertiary)
                    }
                }
            }
        }
        .contextMenu {
            Button("Delete from History", role: .destructive) { model.delete(r.id) }
        }
    }
}
