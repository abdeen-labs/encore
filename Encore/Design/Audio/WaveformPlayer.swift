import EncoreCore
import SwiftUI

/// The card every piece of audio is shown with: waveform (streamed peaks), playhead, click/drag scrubbing,
/// play/pause, elapsed/total, export (WAV / M4A / MP3), reveal in Finder, and drag-out of the file.
/// Playback goes through `NowPlaying`, so starting one card pauses whatever else was playing and the
/// mini-player dock follows along.
///
///     WaveformPlayer(url: take.url, title: "Take 3", subtitle: "Captain · Qwen3-TTS")
///     WaveformPlayer(buffer: result, title: "Preview")
///     WaveformPlayer(url: line.url, title: line.speaker, style: .compact)
struct WaveformPlayer: View {
    enum Style: Sendable { case regular, compact }

    let source: AudioSource
    let title: String
    var subtitle: String?
    var style: Style = .regular
    /// Gallery/preview only: draw the playhead here without a player.
    var previewTime: TimeInterval?

    @State private var loader = WaveformLoader()
    @State private var player: AudioPlayer?
    @State private var pendingStart: TimeInterval = 0
    @State private var scrubTime: TimeInterval?
    @State private var loadError: String?
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    init(url: URL, title: String, subtitle: String? = nil, style: Style = .regular) {
        self.source = .file(url); self.title = title; self.subtitle = subtitle; self.style = style
    }

    init(buffer: AudioBuffer, title: String, subtitle: String? = nil, style: Style = .regular) {
        self.source = .buffer(buffer); self.title = title; self.subtitle = subtitle; self.style = style
    }

    /// Static rendering from peaks, for previews and the gallery (no playback or export).
    init(previewPeaks: WaveformPeaks, title: String, subtitle: String? = nil, style: Style = .regular, time: TimeInterval = 0) {
        self.source = .preview(previewPeaks); self.title = title; self.subtitle = subtitle; self.style = style
        self.previewTime = time
        self._loader = State(initialValue: WaveformLoader(peaks: previewPeaks))
    }

    // MARK: State

    private var duration: TimeInterval { player.map(\.duration).flatMap { $0 > 0 ? $0 : nil } ?? loader.duration }
    private var isPlaying: Bool { player?.isPlaying ?? false }
    private var currentTime: TimeInterval {
        if let scrubTime { return scrubTime }
        if let player, player.isLoaded { return player.currentTime }
        return previewTime ?? pendingStart
    }
    /// The playhead is shown once something has started or been scrubbed.
    private var showsPlayhead: Bool { isPlaying || currentTime > 0.001 }

    var body: some View {
        Group {
            switch style {
            case .regular: regular
            case .compact: compact
            }
        }
        .task(id: sourceID) { await loadPeaks() }
        .onAppear(perform: adoptNowPlaying)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    // MARK: Layouts

    private var regular: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                playButton.controlSize(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).textRole(.headline).lineLimit(1)
                    if let subtitle { Text(subtitle).textRole(.caption).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrag { AudioExportActions.dragProvider(for: source, suggestedName: title) }
                .help(source.canPlay ? "Drag to Finder or another app" : "")
                AudioExportMenu(source: source, suggestedName: title)
            }
            waveform(height: 54, barWidth: 2.5, gap: 1.5)
            HStack {
                Text(Timecode.string(currentTime)).textRole(.monoSmall, color: showsPlayhead ? .tungsten : .textTertiary)
                Spacer()
                if let message = loadError ?? loader.errorMessage {
                    Text(message).textRole(.caption, color: .velvet).lineLimit(1)
                    Spacer()
                }
                Text(duration > 0 ? Timecode.string(duration) : "–:––").textRole(.monoSmall, color: .textTertiary)
            }
            .padding(.top, -Theme.Space.xs)
        }
        .padding(Theme.Space.l)
        .surface(.card)
    }

    private var compact: some View {
        HStack(spacing: Theme.Space.s) {
            playButton.controlSize(.small)
            waveform(height: 26, barWidth: 2, gap: 1.25)
                .onDrag { AudioExportActions.dragProvider(for: source, suggestedName: title) }
            Text(showsPlayhead ? Timecode.string(currentTime, tenths: false) : Timecode.string(duration, tenths: false))
                .textRole(.monoSmall, color: showsPlayhead ? .tungsten : .textSecondary)
                .frame(minWidth: 38, alignment: .trailing)
            AudioExportMenu(source: source, suggestedName: title, symbol: "ellipsis")
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(height: 38)
        .surface(.sunken, radius: Theme.Radius.m)
    }

    private var playButton: some View {
        Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill") { toggle() }
            .buttonStyle(.icon(tone: .accent, filled: true))
            .disabled(!source.canPlay && previewTime == nil)
            .help(isPlaying ? "Pause" : "Play")
    }

    private func waveform(height: CGFloat, barWidth: CGFloat, gap: CGFloat) -> some View {
        GeometryReader { geo in
            let d = max(duration, 0.001)
            ZStack(alignment: .leading) {
                PeaksWaveform(peaks: loader.peaks, played: showsPlayhead ? currentTime : nil, tint: .tungsten,
                              gain: loader.displayGain, barWidth: barWidth, gap: gap, duration: duration > 0 ? duration : nil)
                if showsPlayhead {
                    Playhead().offset(x: min(geo.size.width - 1.5, geo.size.width * currentTime / d))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in scrubTime = min(max(0, g.location.x / max(geo.size.width, 1)), 1) * d }
                .onEnded { _ in
                    if let t = scrubTime { seek(to: t) }
                    scrubTime = nil
                })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Timecode.string(currentTime)) of \(Timecode.string(duration))")
        .accessibilityAdjustableAction { direction in
            seek(to: currentTime + (direction == .increment ? 5 : -5))
        }
    }

    // MARK: Actions

    private var sourceID: String {
        switch source {
        case .file(let url): url.path
        case .buffer(let b): "buffer-\(b.samples.count)-\(b.sampleRate)"
        case .preview: "preview"
        }
    }

    private func loadPeaks() async {
        switch source {
        case .file(let url): await loader.load(url: url)
        case .buffer(let b): await loader.load(buffer: b)
        case .preview: break
        }
        player?.waveform = loader.peaks
    }

    /// If the dock is already playing this file (e.g. the card scrolled away and back), take over that player.
    private func adoptNowPlaying() {
        guard player == nil, let url = source.fileURL, let current = NowPlaying.shared.player,
              current.url?.standardizedFileURL == url.standardizedFileURL else { return }
        player = current
    }

    private func toggle() {
        if let player, player.isLoaded {
            player.toggle()
            return
        }
        Task { await startPlayback() }
    }

    private func startPlayback() async {
        let p = player ?? AudioPlayer(title: title)
        p.title = title
        p.subtitle = subtitle
        do {
            switch source {
            case .file(let url): try await p.load(url: url, title: title)
            case .buffer(let b): p.load(buffer: b, title: title)
            case .preview: return
            }
        } catch {
            loadError = error.localizedDescription
            return
        }
        p.waveform = loader.peaks
        player = p
        if pendingStart > 0 { p.seek(to: pendingStart) }
        p.play()
    }

    private func seek(to t: TimeInterval) {
        let t = min(max(0, t), duration)
        if let player, player.isLoaded { player.seek(to: t) } else { pendingStart = t }
    }
}
