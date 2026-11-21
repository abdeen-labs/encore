import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Speech to speech: someone's performance, in another voice.
///
/// Reads as a signal chain: the recording (cut at pauses into the pieces the model converts one by one) on the
/// left, the voice it should come out in on the right, then the run and the result, which plays back as a
/// before/after pair that stays in step when you flip between them.
struct ChangerScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Changer") { ChangerModel(deps: deps) }
        ChangerStage(model: model)
    }
}

struct ChangerStage: View {
    @Bindable var model: ChangerModel
    @Environment(Router.self) private var router

    var body: some View {
        ScreenScaffold(.changer) {
            content
        } actions: {
            if model.recentTotal > 0 {
                Button("All conversions", systemImage: "clock.arrow.circlepath") { router.go(.history) }
                    .buttonStyle(.ghost)
            }
        }
        .task { await model.prepare() }
    }

    @ViewBuilder private var content: some View {
        if !model.shelf.hasScanned {
            Color.clear.frame(height: 1)
        } else if model.needsFirstModel {
            ChangerFirstRun(model: model)
        } else {
            chain(wide: width >= 800)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .stageAnimation(Theme.Motion.standard, value: model.runner.error == nil)
        }
    }

    @State private var width: CGFloat = 900

    @ViewBuilder private func chain(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    SourcePanel(model: model)
                    performance
                }
                .frame(maxWidth: .infinity)
                PatchCable(lit: model.source != nil && model.voice != nil, busy: model.runner.isRunning)
                    .frame(width: 44)
                    .padding(.top, 70)
                VoicePanel(model: model)
                    .frame(width: 318)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SourcePanel(model: model)
                VoicePanel(model: model)
                performance
            }
        }
    }

    /// Run, result, earlier results: under the recording, so the comparison lands next to what it re-voices.
    @ViewBuilder private var performance: some View {
        notices
        RunSurface(runner: model.runner, title: "Change voice", systemImage: "arrow.triangle.swap",
                   blockedReason: model.runner.error == nil ? model.blockedReason : nil,
                   idleNote: model.idleNote, action: model.convert)
        if let result = model.result {
            ComparisonCard(model: model, result: result)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        RecentConversions(model: model)
    }

    @ViewBuilder private var notices: some View {
        if let error = model.runner.error {
            ServiceErrorBanner(error: error, onDismiss: { withStageAnimation { model.runner.error = nil } }, onRetry: model.convert)
        } else if let m = model.manifest, model.shelf.hasScanned, !model.isDownloaded {
            Banner(.warning, title: "\(m.name) isn't downloaded yet",
                   message: "Get it in Models (\(MemoryGauge.bytes(m.variant(model.choice?.variantID).downloadBytes))). It converts with Chatterbox's speech tokens and decoder.") {
                Button("Get it in Models") { router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
            }
        } else if let problem = model.helperProblem, let m = model.manifest {
            Banner(.warning, title: "\(m.name) runs in the Python helper, which isn't ready",
                   message: ErrorPresentation.clip(problem)) {
                Button("Open Settings") { router.go(.settings) }.buttonStyle(.secondary).controlSize(.small)
            }
        }
    }
}

// MARK: - Source

/// The recording: a drop well until there is one, then its waveform with the pieces it will be converted in.
private struct SourcePanel: View {
    @Bindable var model: ChangerModel
    @State private var isReplacing = false

    static let types: [UTType] = [.audio, .movie, .audiovisualContent]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            StepHeading(number: 1, title: "The performance", detail: model.source == nil ? nil : sourceFacts)
            if let source = model.source {
                WaveformPlayer(track: source.track, cues: cues(source), activeCue: model.activePiece,
                            onCueTap: { source.track.seek(to: $0.start) })
                    .accessory {
                        Button("Replace", systemImage: "arrow.triangle.2.circlepath") { isReplacing = true }
                            .buttonStyle(.icon).controlSize(.small).help("Use a different recording")
                        Button("Remove", systemImage: "xmark") { withStageAnimation { model.clearSource() } }
                            .buttonStyle(.icon).controlSize(.small).help("Remove the recording")
                    }
                    .disabled(model.runner.isBusy)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let u = urls.first, Self.accepts(u), !model.runner.isBusy else { return false }
                        model.setSource(u); return true
                    }
                piecesNote(source)
            } else {
                DropZone(symbol: "waveform.badge.plus", title: "Drop the recording to re-voice",
                         message: "MP3, WAV, M4A or any video · any length · the words and timing stay",
                         allowedTypes: Self.types, minHeight: 186) { urls in
                    if let u = urls.first { withStageAnimation { model.setSource(u) } }
                }
            }
        }
        .fileImporter(isPresented: $isReplacing, allowedContentTypes: Self.types) { result in
            if case .success(let u) = result { model.setSource(u) }
        }
    }

    static func accepts(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { t.conforms(to: $0) }
    }

    private var sourceFacts: String? {
        guard let s = model.source, let info = s.info else { return nil }
        let ext = s.url.pathExtension.uppercased()
        var parts = [info.hasVideo ? "\(ext) video" : (ext.isEmpty ? (info.codec ?? "audio") : ext)]
        parts.append(String(format: "%.0f kHz", info.sampleRate / 1000))
        if info.channelCount > 1 { parts.append("stereo → mono") }
        return parts.joined(separator: " · ")
    }

    private func cues(_ source: ChangerModel.Source) -> [TrackCue] {
        guard let pieces = source.pieces, pieces.count > 1 || model.runner.isRunning else { return [] }
        let active = model.activePiece
        return pieces.map { p in
            let tint: Color = active.map { p.index < $0 ? .mint : (p.index == $0 ? .tungsten : .textTertiary) } ?? .textSecondary
            return TrackCue(id: p.index, start: p.start, end: p.end, tint: tint)
        }
    }

    @ViewBuilder private func piecesNote(_ source: ChangerModel.Source) -> some View {
        HStack(spacing: 6) {
            if let problem = source.problem {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Color.footlight)
                Text(problem).textRole(.caption, color: .textSecondary).lineLimit(2)
            } else if let pieces = source.pieces {
                Image(systemName: "scissors").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.textTertiary)
                if let active = model.activePiece, model.runner.isRunning {
                    Text(active >= pieces.count ? "All \(pieces.count) pieces converted, putting them back together"
                         : "Converting piece \(active + 1) of \(pieces.count) · the rest wait their turn")
                        .textRole(.caption, color: .textSecondary)
                } else if pieces.count == 1 {
                    Text("Short enough to convert in one go.").textRole(.caption, color: .textTertiary)
                } else {
                    Text("Converted in \(pieces.count) pieces, cut at pauses (up to \(Int(model.pieceSeconds)) s each), then put back on the original timeline.")
                        .textRole(.caption, color: .textTertiary).lineLimit(2)
                }
            } else {
                ActivityIndicator(tone: .neutral, size: 10)
                Text("Finding the pauses…").textRole(.caption, color: .textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

/// "1  The performance" over each part of the chain.
private struct StepHeading: View {
    let number: Int
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(String(format: "%02d", number)).font(.mono(11, weight: .semibold)).foregroundStyle(Color.tungsten.opacity(0.8))
            Text(title).font(.display(19)).foregroundStyle(.textPrimary)
            if let detail {
                Text(detail).textRole(.monoSmall, color: .textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Space.xs)
    }
}

/// The patch between source and voice: a dashed line that lights when both ends are connected, and
/// runs while converting.
private struct PatchCable: View {
    let lit: Bool
    let busy: Bool
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !busy || isSnapshotting)) { context in
            let phase = busy && !isSnapshotting ? context.date.timeIntervalSinceReferenceDate * 18 : 0
            ZStack {
                Path { p in p.move(to: CGPoint(x: 4, y: 10)); p.addLine(to: CGPoint(x: 34, y: 10)) }
                    .stroke(lit ? Color.tungsten : Color.textTertiary.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 5], dashPhase: -phase))
                    .glow(.tungsten, radius: 5, intensity: lit ? 0.45 : 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(lit ? Color.tungsten : Color.textTertiary)
                    .offset(x: 17)
            }
            .frame(width: 40, height: 20)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Voice

/// The voice it should come out in (library voices only: the changer needs a reference clip), the model,
/// and its tuning.
private struct VoicePanel: View {
    @Bindable var model: ChangerModel
    @Environment(Router.self) private var router
    @State private var reference = AudioPlayer()
    @State private var auditioning: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            StepHeading(number: 2, title: "The new voice", detail: model.hasVoices ? "\(model.voices.voices.count) in your company" : nil)
            VStack(alignment: .leading, spacing: 0) {
                if model.hasVoices { voiceList } else { noVoices }
                Rectangle().fill(Color.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ModelPicker(task: .voiceConversion, feature: .voiceChange, selection: $model.choice)
                    if model.helperProblem != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Color.footlight)
                            Text("Needs the Python helper, which isn't set up.").textRole(.caption, color: .textSecondary)
                            Spacer(minLength: 4)
                            Button("Settings") { router.go(.settings) }.buttonStyle(.ghost).controlSize(.small)
                        }
                    }
                    tuning
                }
                .padding(Theme.Space.m)
            }
            .surface(.card)
        }
    }

    private var voiceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.voices.voices.count > 5 {
                SearchField(text: $model.voiceQuery, prompt: "Search voices and tags")
                    .padding([.horizontal, .top], Theme.Space.s)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.filteredVoices) { v in row(v) }
                    if model.filteredVoices.isEmpty {
                        Text("Nothing matches “\(model.voiceQuery)”.").textRole(.caption).padding(Theme.Space.m)
                    }
                }
                .padding(Theme.Space.s)
            }
            .frame(maxHeight: 236)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ v: Voice) -> some View {
        let selected = model.voiceID == v.id
        return PickerRow(isSelected: selected, action: { model.voiceID = v.id }) {
            Button {
                toggleReference(v)
            } label: {
                Image(systemName: auditioning == v.id && reference.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(selected ? Color.onTungsten : Color.tungsten)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(selected ? Color.tungsten : Color.tungsten.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Hear \(v.name)'s reference clip")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(v.name).textRole(.headline, color: selected ? .textPrimary : .textSecondary).lineLimit(1)
                    Image(systemName: v.origin.symbol).font(.system(size: 9)).foregroundStyle(.textTertiary)
                        .help(v.origin.label)
                }
                if !v.tags.isEmpty {
                    Text(v.tags.prefix(3).joined(separator: " · ")).textRole(.caption, color: .textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(Timecode.seconds(v.duration)).textRole(.monoSmall, color: .textTertiary)
        }
    }

    private func toggleReference(_ v: Voice) {
        if auditioning == v.id, reference.isPlaying { reference.pause(); return }
        guard let url = model.voices.referenceAudioURL(for: v.id) else { return }
        auditioning = v.id
        Task {
            try? await reference.load(url: url, title: v.name)
            reference.subtitle = "Reference clip"
            reference.play()
        }
    }

    private var noVoices: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.tungsten).glow(.tungsten, radius: 8, intensity: 0.35)
                Text("No voices to change into yet").textRole(.headline)
            }
            Text("The changer needs a voice from your library: a few seconds of someone speaking. Clone one from a recording, or design one from a description.")
                .textRole(.caption).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Clone a voice", systemImage: "mic") { router.go(.clone) }.buttonStyle(.secondary).controlSize(.small)
                Button("Design one", systemImage: "wand.and.stars") { router.go(.design) }.buttonStyle(.ghost).controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(Theme.Space.l)
    }

    @ViewBuilder private var tuning: some View {
        if let m = model.manifest {
            AdvancedDisclosure("Tuning", isExpanded: $model.showTuning) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    StageSlider("Longest piece", value: $model.pieceSeconds, in: 6...30, step: 1, defaultValue: 20) { "\(Int($0)) s" }
                        .help("Long recordings are cut at pauses into pieces no longer than this, converted one by one, and put back on the original timeline.")
                    ParameterPanel(manifest: m, values: $model.parameters)
                    PerforatedDivider(notchFill: .surface).padding(.vertical, Theme.Space.xxs)
                    HStack {
                        Text("Finishing").textRole(.eyebrow)
                        Spacer()
                        PresetsMenu(manifest: m, parameters: $model.parameters, post: $model.post)
                    }
                    PostProcessingControls(options: $model.post)
                }
                .padding(.top, Theme.Space.xs)
            }
        }
    }
}

// MARK: - Result

/// The conversion and its original, one above the other on the same timeline. Flip between them and playback
/// carries on from the same moment.
private struct ComparisonCard: View {
    @Bindable var model: ChangerModel
    let result: ChangerModel.Result
    @State private var scrub: TimeInterval?
    @State private var originalScrub: TimeInterval?

    private var active: PlaybackTrack { model.side == .original ? (result.original ?? result.track) : result.track }

    var body: some View {
        let track = active
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Button(track.isPlaying ? "Pause" : "Play", systemImage: track.isPlaying ? "pause.fill" : "play.fill") { track.toggle() }
                    .buttonStyle(.icon(tone: .accent, filled: true))
                    .controlSize(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.record.voiceName.map { "In \($0)'s voice" } ?? "Converted").textRole(.headline).lineLimit(1)
                    Text("\(Timecode.string(result.record.duration, tenths: false)) · \(result.record.modelName) · in History").textRole(.caption).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if result.original != nil {
                    SegmentedControl(selection: Binding(get: { model.side }, set: { model.switchSide(to: $0) }),
                                     options: ChangerModel.Side.allCases) { $0.rawValue }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Flip between them: playback continues from the same moment")
                }
                AudioExportMenu(source: result.track.source, suggestedName: result.record.title)
                Button("Close", systemImage: "xmark") { withStageAnimation { model.dismissResult() } }
                    .buttonStyle(.icon).controlSize(.small)
            }
            lane(label: "Converted", track: result.track, tint: .tungsten, height: 52, on: model.side == .converted, scrub: $scrub)
            if let original = result.original {
                lane(label: "Original", track: original, tint: .mint, height: 30, on: model.side == .original, scrub: $originalScrub)
            } else {
                Text("The original recording isn't where it was, so there's nothing to compare against.")
                    .textRole(.caption, color: .textTertiary)
            }
            HStack {
                Text(Timecode.string(scrub ?? originalScrub ?? track.currentTime)).textRole(.monoSmall, color: track.hasPosition ? .tungsten : .textTertiary)
                Spacer()
                Text("\(model.side.rawValue) playing").textRole(.caption, color: .textTertiary)
                Spacer()
                Text(Timecode.string(max(result.track.duration, result.record.duration))).textRole(.monoSmall, color: .textTertiary)
            }
        }
        .padding(Theme.Space.l)
        .surface(.card)
        .overlay(alignment: .top) {
            Rectangle().fill(LinearGradient(colors: [.clear, Color.tungsten.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1).padding(.horizontal, Theme.Space.xl)
        }
        .task(id: result.original?.url) { await result.original?.loadPeaks() }
        .task(id: result.track.url) { await result.track.loadPeaks() }
    }

    /// One side of the comparison. Its playhead mirrors whichever side is playing; clicking it switches to it there.
    private func lane(label: String, track: PlaybackTrack, tint: Color, height: CGFloat, on: Bool, scrub: Binding<TimeInterval?>) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Text(label).textRole(.eyebrow, color: on ? tint : .textTertiary)
                .lineLimit(1).fixedSize()
                .frame(width: 86, alignment: .leading)
            TrackWaveform(track: track, height: height, tint: on ? tint : .textSecondary, barWidth: height > 40 ? 2.5 : 2,
                          gap: 1.5, showsPlayhead: active.hasPosition, mirroredTime: on ? nil : active.currentTime, scrubTime: scrub)
                .opacity(on ? 1 : 0.6)
                .simultaneousGesture(TapGesture().onEnded {
                    let side: ChangerModel.Side = track === result.track ? .converted : .original
                    if side != model.side { model.switchSide(to: side) }
                })
        }
    }
}

/// Earlier conversions, to bring one back into the comparison.
private struct RecentConversions: View {
    let model: ChangerModel
    @Environment(Router.self) private var router

    var body: some View {
        let items = model.recent.filter { $0.id != model.result?.record.id }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    Text("Earlier conversions").textRole(.eyebrow)
                    Rectangle().fill(Color.hairline).frame(height: 1)
                    if model.recentTotal > model.recent.count {
                        Button("All \(model.recentTotal) in History") { router.go(.history) }.buttonStyle(.ghost).controlSize(.small)
                    }
                }
                ForEach(items.prefix(5)) { item in
                    if let r = item.generation {
                        Button { withStageAnimation { model.show(r) } } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "arrow.triangle.swap").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.tungsten.opacity(0.7))
                                Text(r.text).textRole(.body).lineLimit(1)
                                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.textTertiary)
                                Text(r.voiceName ?? "—").textRole(.body, color: .textSecondary).lineLimit(1)
                                Spacer(minLength: Theme.Space.s)
                                Text(Timecode.string(r.duration, tenths: false)).textRole(.monoSmall, color: .textTertiary)
                                Text(r.createdAt, style: .relative).textRole(.caption, color: .textTertiary).lineLimit(1)
                                    .frame(width: 92, alignment: .trailing)
                            }
                            .padding(.horizontal, Theme.Space.m)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }
            .padding(.top, Theme.Space.s)
        }
    }
}

/// A flat list row that lifts on hover.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowButton(configuration: configuration) }

    private struct RowButton: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(Color.textPrimary.opacity(configuration.isPressed ? 0.08 : (hovered ? 0.045 : 0))))
                .onHover { hovered = $0 }
        }
    }
}

// MARK: - First run

/// No voice changer on disk: lead to Models, saying what the changer needs.
private struct ChangerFirstRun: View {
    let model: ChangerModel
    @Environment(Router.self) private var router

    var body: some View {
        let m = model.shelf.manifests(for: .voiceConversion).first
        VStack(spacing: Theme.Space.xl) {
            EmptyState(symbol: "arrow.triangle.swap", title: "Same performance, new voice",
                       message: "The voice changer keeps the words, timing and delivery of a recording and re-voices it in one of your voices. It needs its model first.") {
                Button("Open Models", systemImage: "arrow.down.circle") { router.go(.models) }
                    .buttonStyle(.primary).controlSize(.large)
            }
            if let m {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(m.name).textRole(.heading)
                        Text(m.summary).textRole(.caption).fixedSize(horizontal: false, vertical: true)
                        PerforatedDivider(notchFill: .surface).padding(.vertical, 2)
                        HStack(spacing: Theme.Space.m) {
                            Text("\(MemoryGauge.bytes(m.defaultVariant.downloadBytes)) download").textRole(.mono, color: .textSecondary)
                            Text("Python helper").textRole(.monoSmall, color: .textTertiary)
                            Spacer()
                            Text(m.license.name).textRole(.monoSmall, color: .textTertiary)
                        }
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: 520)
                .surface(.card)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.l)
    }
}
