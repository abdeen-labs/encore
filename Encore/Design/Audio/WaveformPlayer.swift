import EncoreCore
import SwiftUI

/// The card every piece of audio is shown with: waveform (streamed peaks), playhead, click/drag scrubbing,
/// play/pause, elapsed/total, export (WAV / M4A / MP3), reveal in Finder, and drag-out of the file.
/// Playback goes through `NowPlaying`, so starting one card pauses whatever else was playing and the
/// mini-player dock follows along.
///
/// By default the card keeps its own `PlaybackTrack`. A screen that needs to seek it or follow its playhead
/// passes one in with `track:`, optionally with cues (transcript segments, script lines) drawn under the
/// waveform.
///
///     WaveformPlayer(url: take.url, title: "Take 3", subtitle: "Captain · Qwen3-TTS")
///     WaveformPlayer(buffer: result, title: "Preview")
///     WaveformPlayer(url: line.url, title: line.speaker, style: .compact)
///     WaveformPlayer(url: row.url, title: row.title, style: .minimal)     // dense list rows: play + duration
///     WaveformPlayer(track: model.track, cues: cues, activeCue: active, onCueTap: { model.track.play(from: $0.start) })
///
/// The play button is unlit at rest and lit only while this audio plays (`.play(isPlaying:)`).
struct WaveformPlayer: View {
    enum Style: Sendable {
        /// A card: one header row (play, title, subtitle, accessory, export), the waveform, timecodes.
        case regular
        /// A slim sunken strip: play, waveform, time, accessory, export menu.
        case compact
        /// Just the play button and the duration (elapsed / total while playing). No waveform, no card, no
        /// accessory or export menu. For dense list rows.
        case minimal
    }

    /// A track the caller owns; when nil the card uses its own.
    private let external: PlaybackTrack?
    private let source: AudioSource
    private let title: String
    private let subtitle: String?
    var style: Style = .regular
    var cues: [TrackCue] = []
    var activeCue: Int?
    var onCueTap: ((TrackCue) -> Void)?
    /// Extra controls in the header, before the export menu (e.g. a take's star and menu). Set with `.accessory { }`.
    var accessory: AnyView?

    @State private var owned: PlaybackTrack?
    @State private var scrubTime: TimeInterval?

    init(url: URL, title: String, subtitle: String? = nil, style: Style = .regular) {
        self.init(source: .file(url), title: title, subtitle: subtitle, style: style)
    }

    init(buffer: AudioBuffer, title: String, subtitle: String? = nil, style: Style = .regular) {
        self.init(source: .buffer(buffer), title: title, subtitle: subtitle, style: style)
    }

    /// Static rendering from peaks, for previews and the gallery (no playback or export).
    init(previewPeaks: WaveformPeaks, title: String, subtitle: String? = nil, style: Style = .regular, time: TimeInterval = 0) {
        self.init(source: .preview(previewPeaks), title: title, subtitle: subtitle, style: style, previewTime: time)
    }

    /// A track the caller keeps, to seek it or follow its playhead; `cues` are marked under the waveform.
    init(track: PlaybackTrack, style: Style = .regular, cues: [TrackCue] = [], activeCue: Int? = nil,
         onCueTap: ((TrackCue) -> Void)? = nil) {
        external = track
        source = track.source; title = track.title; subtitle = track.subtitle
        self.style = style; self.cues = cues; self.activeCue = activeCue; self.onCueTap = onCueTap
    }

    private init(source: AudioSource, title: String, subtitle: String?, style: Style, previewTime: TimeInterval = 0) {
        external = nil
        self.source = source; self.title = title; self.subtitle = subtitle; self.style = style
        _owned = State(initialValue: PlaybackTrack(source: source, title: title, subtitle: subtitle, previewTime: previewTime))
    }

    // MARK: State

    /// The track on show: the caller's, or this card's own (replaced when the card is pointed at other audio).
    private var track: PlaybackTrack {
        if let external { return external }
        return owned ?? PlaybackTrack(source: source, title: title, subtitle: subtitle)
    }
    private var isPreview: Bool { if case .preview = source { true } else { false } }

    var body: some View {
        let track = track
        Group {
            switch style {
            case .regular: regular(track)
            case .compact: compact(track)
            case .minimal: minimal(track)
            }
        }
        .task(id: PlaybackTrack.key(for: source)) {
            if external == nil, owned?.sourceKey != PlaybackTrack.key(for: source) {
                owned = PlaybackTrack(source: source, title: title, subtitle: subtitle)
            }
            await self.track.loadPeaks()
        }
        .onChange(of: title) { _, t in if external == nil { owned?.title = t } }
        .onChange(of: subtitle) { _, s in if external == nil { owned?.subtitle = s } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(track.title)
    }

    // MARK: Layouts

    private func regular(_ track: PlaybackTrack) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                playButton(track).controlSize(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(external?.title ?? title).textRole(.headline).lineLimit(1)
                    if let subtitle = external?.subtitle ?? subtitle { Text(subtitle).textRole(.caption).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrag { AudioExportActions.dragProvider(for: track.source, suggestedName: track.title) }
                .help(track.source.canPlay ? "Drag to Finder or another app" : "")
                if let accessory { accessory }
                AudioExportMenu(source: track.source, suggestedName: track.title)
            }
            TrackWaveform(track: track, height: 54, scrubTime: $scrubTime)
            if !cues.isEmpty {
                CueLane(cues: cues, duration: track.duration, active: activeCue, onTap: onCueTap)
                    .padding(.top, -Theme.Space.s)
            }
            HStack {
                Text(Timecode.string(scrubTime ?? track.currentTime))
                    .textRole(.monoSmall, color: track.isPlaying ? .tungsten : (track.hasPosition ? .textSecondary : .textTertiary))
                Spacer()
                if let message = track.loadError ?? track.loader.errorMessage {
                    Text(message).textRole(.caption, color: .velvetText).lineLimit(1)
                    Spacer()
                }
                Text(track.duration > 0 ? Timecode.string(track.duration) : "–:––").textRole(.monoSmall, color: .textTertiary)
            }
            .padding(.top, -Theme.Space.xs)
        }
        .padding(Theme.Space.l)
        .surface(.card)
    }

    private func compact(_ track: PlaybackTrack) -> some View {
        HStack(spacing: Theme.Space.s) {
            playButton(track).controlSize(.small)
            TrackWaveform(track: track, height: 26, barWidth: 2, gap: 1.25, scrubTime: $scrubTime)
                .onDrag { AudioExportActions.dragProvider(for: track.source, suggestedName: track.title) }
            let shown = track.hasPosition || scrubTime != nil
            Text(Timecode.string(shown ? (scrubTime ?? track.currentTime) : track.duration, tenths: false))
                .textRole(.monoSmall, color: track.isPlaying ? .tungsten : (shown ? .textPrimary : .textSecondary))
                .frame(minWidth: 38, alignment: .trailing)
            if let accessory { accessory }
            AudioExportMenu(source: track.source, suggestedName: track.title, symbol: "ellipsis")
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(height: 38)
        .surface(.sunken, radius: Theme.Radius.m)
    }

    private func minimal(_ track: PlaybackTrack) -> some View {
        HStack(spacing: Theme.Space.s) {
            playButton(track).controlSize(.small)
            let shown = track.hasPosition || track.isPlaying
            let total = track.duration > 0 ? Timecode.string(track.duration, tenths: false) : "–:––"
            Text(verbatim: shown ? "\(Timecode.string(track.currentTime, tenths: false)) / \(total)" : total)
                .textRole(.monoSmall, color: track.isPlaying ? .tungsten : (shown ? .textPrimary : .textSecondary))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .onDrag { AudioExportActions.dragProvider(for: track.source, suggestedName: track.title) }
        }
        .fixedSize()
    }

    private func playButton(_ track: PlaybackTrack) -> some View {
        Button(track.isPlaying ? "Pause" : "Play", systemImage: track.isPlaying ? "pause.fill" : "play.fill") { track.toggle() }
            .buttonStyle(.play(isPlaying: track.isPlaying))
            .disabled(!track.source.canPlay && !(isPreview && track.hasPosition))
            .help(track.isPlaying ? "Pause" : "Play")
    }

    /// Adds controls to the card's header, before the export menu.
    func accessory<V: View>(@ViewBuilder _ content: () -> V) -> WaveformPlayer {
        var copy = self
        copy.accessory = AnyView(content())
        return copy
    }
}
