import EncoreCore
import SwiftUI

/// The global mini-player under the stage. It follows `NowPlaying.shared`: whatever any waveform card (or
/// feature) last played shows here with its waveform, transport and time. Until something plays it isn't
/// there at all (the stage takes the space); it slides in when something plays and leaves when dismissed.
/// `RootView` animates the change, honoring Reduce Motion.
struct PlayerDock: View {
    @State private var loader = WaveformLoader()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let nowPlaying = NowPlaying.shared
        if let player = nowPlaying.player {
            PlayerDockBar(title: player.title ?? "Untitled", subtitle: player.subtitle,
                          peaks: player.waveform ?? loader.peaks, gain: player.waveform.map(WaveformLoader.gain) ?? loader.displayGain,
                          currentTime: player.currentTime, duration: player.duration, isPlaying: player.isPlaying,
                          onToggle: { player.toggle() }, onSeek: { player.seek(to: $0) },
                          onDismiss: { withStageAnimation { nowPlaying.dismiss() } })
                .task(id: player.id) {
                    if player.waveform == nil, let url = player.url { await loader.load(url: url) }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The dock's drawing, driven by plain values so it can be previewed without audio.
struct PlayerDockBar: View {
    var title: String?
    var subtitle: String?
    var peaks: WaveformPeaks?
    var gain: Float = 1
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var onToggle: () -> Void = {}
    var onSeek: (TimeInterval) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    @State private var scrubTime: TimeInterval?

    /// A bar with nothing loaded. The app no longer shows one (the dock is absent until something plays); kept
    /// for previews.
    static var idle: PlayerDockBar { PlayerDockBar() }
    private var isIdle: Bool { title == nil }
    private var shownTime: TimeInterval { scrubTime ?? currentTime }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill", action: onToggle)
                .buttonStyle(.play(isPlaying: isPlaying))
                .controlSize(.small)
                .disabled(isIdle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? "Nothing playing")
                    .textRole(.label, color: isIdle ? .textTertiary : .textPrimary)
                    .lineLimit(1)
                if let subtitle, !isIdle {
                    Text(subtitle).textRole(.caption).lineLimit(1)
                }
            }
            .frame(width: 190, alignment: .leading)
            waveform
            Text(isIdle ? "0:00" : "\(Timecode.string(shownTime, tenths: false)) / \(Timecode.string(duration, tenths: false))")
                .textRole(.monoSmall, color: isIdle ? .textTertiary : .textSecondary)
                .monospacedDigit()
                .fixedSize()
            Button("Close player", systemImage: "xmark", action: onDismiss)
                .buttonStyle(.icon)
                .controlSize(.small)
                .opacity(isIdle ? 0 : 1)
                .disabled(isIdle)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 46)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
    }

    private var waveform: some View {
        GeometryReader { geo in
            let d = max(duration, 0.001)
            ZStack(alignment: .leading) {
                if isIdle {
                    Hairline().frame(maxHeight: .infinity)
                } else {
                    PeaksWaveform(peaks: peaks, played: shownTime, tint: .tangerine, gain: gain,
                                  barWidth: 1.5, gap: 1.5, duration: duration > 0 ? duration : nil)
                    Playhead().offset(x: min(geo.size.width - 1.5, geo.size.width * shownTime / d))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard !isIdle else { return }
                    scrubTime = min(max(0, g.location.x / max(geo.size.width, 1)), 1) * d
                }
                .onEnded { _ in
                    if let t = scrubTime { onSeek(t) }
                    scrubTime = nil
                })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(isIdle ? "Nothing playing" : "\(Timecode.string(shownTime)) of \(Timecode.string(duration))")
    }
}
