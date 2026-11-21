import EncoreCore
import SwiftUI

/// One piece of audio and its playback state: peaks (through `WaveformLoader`), the player (created on first
/// play, going through `NowPlaying` like everything else), the playhead and a pending start position.
/// `WaveformPlayer` makes its own; a screen that needs to drive or follow the playhead (seek from a transcript
/// segment, keep two in step) makes one, keeps it, and hands it to `WaveformPlayer(track:)`.
///
///     let track = PlaybackTrack(url: record.audioURL, title: "Take 3")
///     WaveformPlayer(track: track, cues: segments.map { … }, activeCue: i)
///     track.play(from: 12.5)
@MainActor @Observable
final class PlaybackTrack: Identifiable {
    let id = UUID()
    let source: AudioSource
    var title: String
    var subtitle: String?
    let loader: WaveformLoader
    private(set) var player: AudioPlayer?
    private(set) var loadError: String?
    /// Where playback starts when the player isn't loaded yet (for previews: where the playhead is drawn).
    private var pendingStart: TimeInterval = 0

    convenience init(url: URL, title: String, subtitle: String? = nil) {
        self.init(source: .file(url), title: title, subtitle: subtitle)
    }

    init(source: AudioSource, title: String, subtitle: String? = nil, previewTime: TimeInterval = 0) {
        self.source = source
        self.title = title
        self.subtitle = subtitle
        if case .preview(let peaks) = source {
            loader = WaveformLoader(peaks: peaks)
            pendingStart = previewTime
        } else {
            loader = WaveformLoader()
        }
        adoptNowPlaying()
    }

    /// The file, for file tracks.
    var url: URL? { source.fileURL }

    /// Identity of what's played: the file path, or the buffer's shape.
    var sourceKey: String { Self.key(for: source) }

    static func key(for source: AudioSource) -> String {
        switch source {
        case .file(let url): url.standardizedFileURL.path
        case .buffer(let b): "buffer-\(b.samples.count)-\(b.sampleRate)-\(b.samples.prefix(64).hashValue)"
        case .preview(let p): "preview-\(p.count)-\(p.duration)"
        }
    }

    var duration: TimeInterval {
        if let p = player, p.isLoaded, p.duration > 0 { return p.duration }
        return max(loader.duration, loader.peaks?.duration ?? 0)
    }
    var currentTime: TimeInterval {
        if let p = player, p.isLoaded { return p.currentTime }
        return pendingStart
    }
    var isPlaying: Bool { player?.isPlaying ?? false }
    /// Something has played or been scrubbed, so the playhead is worth showing.
    var hasPosition: Bool { isPlaying || currentTime > 0.001 }

    /// Loads the waveform. Safe to call from any number of views: they share the one read.
    func loadPeaks() async {
        switch source {
        case .file(let url): await loader.load(url: url)
        case .buffer(let b): await loader.load(buffer: b)
        case .preview: break
        }
        player?.waveform = loader.peaks
    }

    func toggle() {
        if let p = player, p.isLoaded { p.toggle(); return }
        Task { await start(at: pendingStart) }
    }

    func play(from time: TimeInterval? = nil) {
        if let p = player, p.isLoaded {
            if let time { p.seek(to: time) }
            if !p.isPlaying { p.play() }
            return
        }
        Task { await start(at: time ?? pendingStart) }
    }

    func pause() { player?.pause() }

    func seek(to time: TimeInterval) {
        let t = max(0, duration > 0 ? min(time, duration) : time)
        if let p = player, p.isLoaded { p.seek(to: t) } else { pendingStart = t }
    }

    private func start(at time: TimeInterval) async {
        guard source.canPlay else { return }
        let p = player ?? AudioPlayer(title: title)
        p.title = title
        p.subtitle = subtitle
        do {
            switch source {
            case .file(let url):
                if !p.isLoaded || p.url?.standardizedFileURL != url.standardizedFileURL { try await p.load(url: url, title: title) }
            case .buffer(let b):
                if !p.isLoaded { p.load(buffer: b, title: title) }
            case .preview:
                return
            }
        } catch {
            loadError = error.localizedDescription
            return
        }
        loadError = nil
        p.waveform = loader.peaks
        player = p
        if time > 0 { p.seek(to: time) }
        p.play()
    }

    /// If the dock already plays this file (the view was left and came back), take over that player.
    private func adoptNowPlaying() {
        guard let url, let current = NowPlaying.shared.player,
              current.url?.standardizedFileURL == url.standardizedFileURL else { return }
        player = current
    }
}

/// A span of a track worth marking: a transcript segment, a line of a script.
struct TrackCue: Identifiable, Hashable {
    var id: Int
    var start: TimeInterval
    var end: TimeInterval
    var tint: Color = .tungsten
}

/// A track's waveform with playhead and click/drag scrubbing. `WaveformPlayer` draws its waveform with this;
/// use it directly only for custom layouts (e.g. Changer's before/after lanes).
struct TrackWaveform: View {
    let track: PlaybackTrack
    var height: CGFloat = 54
    var tint: Color = .tungsten
    var barWidth: CGFloat = 2.5
    var gap: CGFloat = 1.5
    /// Show the playhead even before anything has played (e.g. the lane that follows another).
    var showsPlayhead: Bool?
    /// Draw the playhead at this time instead of the track's own (a lane mirroring another one).
    var mirroredTime: TimeInterval?
    @Binding var scrubTime: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let d = max(track.duration, 0.001)
            let time = scrubTime ?? mirroredTime ?? track.currentTime
            let lit = showsPlayhead ?? track.hasPosition
            ZStack(alignment: .leading) {
                PeaksWaveform(peaks: track.loader.peaks, played: lit ? time : nil, tint: tint,
                              gain: track.loader.displayGain, barWidth: barWidth, gap: gap,
                              duration: track.duration > 0 ? track.duration : nil)
                if lit {
                    Playhead().offset(x: min(geo.size.width - 1.5, geo.size.width * time / d))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in scrubTime = min(max(0, g.location.x / max(geo.size.width, 1)), 1) * d }
                .onEnded { _ in
                    if let t = scrubTime { track.seek(to: t) }
                    scrubTime = nil
                })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Timecode.string(track.currentTime)) of \(Timecode.string(track.duration))")
        .accessibilityAdjustableAction { direction in
            track.seek(to: track.currentTime + (direction == .increment ? 5 : -5))
        }
    }
}

/// Thin bars under a waveform marking cues; the active one glows. Clicking a bar seeks to it.
struct CueLane: View {
    let cues: [TrackCue]
    let duration: TimeInterval
    var active: Int?
    var onTap: ((TrackCue) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let d = max(duration, cues.last?.end ?? 0, 0.001)
            ZStack(alignment: .leading) {
                ForEach(cues) { cue in
                    let x = geo.size.width * cue.start / d
                    let w = max(2, geo.size.width * (cue.end - cue.start) / d - 1.5)
                    let on = cue.id == active
                    Capsule()
                        .fill(cue.tint.opacity(on ? 1 : 0.38))
                        .frame(width: w, height: on ? 4 : 3)
                        .glow(cue.tint, radius: on ? 5 : 0, intensity: on ? 0.6 : 0)
                        .offset(x: x)
                        .onTapGesture { onTap?(cue) }
                }
            }
            .frame(height: 8)
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
