@preconcurrency import AVFoundation
import Foundation
import Observation

/// Plays one file or buffer. Bind SwiftUI views to its properties; `currentTime` updates ~30× a second while
/// playing. Only one player plays at a time: starting one pauses whatever `NowPlaying.shared` had.
///
/// The observable state lives on the main actor and changes immediately; every call into the audio engine
/// (`AVAudioPlayerNode.stop()`, `AVAudioEngine.start()`/`pause()` block on the engine's own lower-priority
/// thread) runs on one serial queue, so the main thread never waits on it and commands keep their order.
@MainActor @Observable
public final class AudioPlayer: Identifiable {
    public let id = UUID()
    /// Shown by the global mini-player.
    public var title: String?
    /// Second line for the global mini-player (voice, model…).
    public var subtitle: String?
    /// Peaks of the loaded audio, when whoever loaded it has them, so the mini-player can draw the same waveform.
    public var waveform: WaveformPeaks?
    /// The file being played (nil for buffer content).
    public private(set) var url: URL?
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPlaying = false
    /// `currentTime / duration`, 0…1.
    public var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }
    public private(set) var isLoaded = false
    /// The sub-range being auditioned, if `play(range:)` started playback.
    public private(set) var activeRange: ClosedRange<TimeInterval>?
    public var volume: Float = 1 { didSet { engine.setVolume(volume) } }
    public private(set) var lastError: String?

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private var sampleRate: Double?
    @ObservationIgnored private var segmentStart: TimeInterval = 0
    @ObservationIgnored private var segmentEnd: TimeInterval = 0
    /// Bumped by every command that ends or replaces a segment; completions and playhead reports from an
    /// older generation are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var temporaryFile: URL?

    public init(title: String? = nil) {
        self.title = title
        engine = PlaybackEngine(offline: false)
    }

    /// A player whose engine renders offline and never reaches an output device (tests).
    init(title: String? = nil, offline: Bool) {
        self.title = title
        engine = PlaybackEngine(offline: offline)
    }

    isolated deinit {
        ticker?.cancel()
        engine.shutdown()
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
    }

    /// Loads any audio or video file. Formats AVFoundation can't play directly (mkv, webm…) are decoded to a
    /// temporary WAV first.
    public func load(url: URL, title: String? = nil) async throws {
        stop()
        let playable: AVAudioFile
        if let f = try? AVAudioFile(forReading: url), f.length > 0 {
            playable = f
        } else {
            let wav = try await AudioPreparation.wav(from: url, encoding: .float32)
            if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
            temporaryFile = wav
            playable = try AVAudioFile(forReading: wav)
        }
        stop()
        engine.setSource(.file(playable), volume: volume)
        sampleRate = playable.processingFormat.sampleRate
        self.url = url
        self.title = title ?? self.title ?? url.deletingPathExtension().lastPathComponent
        duration = Double(playable.length) / playable.processingFormat.sampleRate
        currentTime = 0
        isLoaded = true
    }

    /// Loads in-memory audio (e.g. a fresh result before it's saved).
    public func load(buffer: AudioBuffer, title: String? = nil) {
        stop()
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.sampleRate, channels: 1, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, buffer.samples.count))) else {
            lastError = "Unsupported audio."
            return
        }
        b.frameLength = AVAudioFrameCount(buffer.samples.count)
        buffer.samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { b.floatChannelData![0].update(from: base, count: src.count) }
        }
        engine.setSource(.buffer(b), volume: volume)
        sampleRate = fmt.sampleRate
        url = nil
        if let title { self.title = title }
        duration = buffer.duration
        currentTime = 0
        isLoaded = true
    }

    public func play() {
        if let activeRange, currentTime < activeRange.upperBound - 0.01, currentTime >= activeRange.lowerBound {
            start(from: currentTime, to: activeRange.upperBound)
        } else {
            activeRange = nil
            start(from: currentTime >= duration - 0.01 ? 0 : currentTime, to: duration)
        }
    }

    /// Plays just `range` (e.g. a trim selection), then stops at its end and returns to its start.
    public func play(range: ClosedRange<TimeInterval>) {
        let r = max(0, range.lowerBound)...min(duration, range.upperBound)
        activeRange = r
        start(from: r.lowerBound, to: r.upperBound)
    }

    public func pause() {
        guard isPlaying else { return }
        halt(reportingPosition: true)
    }

    public func toggle() { isPlaying ? pause() : play() }

    /// Stops and rewinds.
    public func stop() {
        halt(reportingPosition: false)
        currentTime = activeRange?.lowerBound ?? 0
        activeRange = nil
    }

    public func seek(to time: TimeInterval) {
        let t = min(max(0, time), duration)
        if let r = activeRange, !r.contains(t) { activeRange = nil }
        if isPlaying {
            start(from: t, to: activeRange?.upperBound ?? duration)
        } else {
            generation += 1 // a pause still reporting its final position must not overwrite this
            currentTime = t
        }
    }

    // MARK: Internals

    private func start(from: TimeInterval, to: TimeInterval) {
        guard isLoaded, let sampleRate, to > from else { return }
        let startFrame = AVAudioFramePosition((from * sampleRate).rounded())
        let endFrame = AVAudioFramePosition((to * sampleRate).rounded())
        guard endFrame > startFrame else { return }
        NowPlaying.shared.willPlay(self)
        generation += 1
        let gen = generation
        segmentStart = from
        segmentEnd = to
        currentTime = from
        isPlaying = true
        lastError = nil
        engine.play(startFrame: startFrame, frames: AVAudioFrameCount(endFrame - startFrame),
                    completion: { [weak self] in self?.finished(generation: gen) },
                    failure: { [weak self] message in self?.failed(generation: gen, message: message) })
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying, self.generation == gen else { return }
                self.engine.position { [weak self] seconds in self?.apply(position: seconds, generation: gen) }
            }
        }
    }

    /// Ends the current segment. With `reportingPosition`, the engine reports where it actually was so a pause
    /// lands on the audible position rather than the last tick's.
    private func halt(reportingPosition: Bool) {
        generation += 1
        let gen = generation
        ticker?.cancel()
        ticker = nil
        isPlaying = false
        var report: (@MainActor @Sendable (TimeInterval?) -> Void)?
        if reportingPosition {
            report = { [weak self] seconds in self?.apply(position: seconds, generation: gen) }
        }
        engine.halt(position: report)
    }

    private func apply(position seconds: TimeInterval?, generation gen: Int) {
        guard gen == generation, let seconds else { return }
        currentTime = min(segmentEnd, segmentStart + max(0, seconds))
    }

    private func finished(generation gen: Int) {
        guard gen == generation else { return }
        halt(reportingPosition: false)
        currentTime = activeRange?.lowerBound ?? 0
    }

    private func failed(generation gen: Int, message: String) {
        guard gen == generation else { return }
        halt(reportingPosition: false)
        lastError = AudioError.playbackFailed(message).localizedDescription
    }

    #if DEBUG
    /// Waits until every engine command issued so far has run (tests).
    func drainEngine() async { await engine.drain() }
    /// Renders `seconds` of an offline player's output so its scheduled audio plays through (tests).
    func renderOffline(seconds: Double) async { await engine.renderOffline(seconds: seconds) }
    #endif
}

/// Owns the `AVAudioEngine` and does all its work on one serial queue. Callbacks hop back to the main actor.
private final class PlaybackEngine: @unchecked Sendable {
    /// Handed to the queue once and only read there afterwards.
    enum Source: @unchecked Sendable { case file(AVAudioFile), buffer(AVAudioPCMBuffer) }

    // Touched only on `queue`.
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var source: Source?
    private let offline: Bool
    /// Default priority, the same as the engine's own thread that `node.stop()` waits on. A higher one makes
    /// this queue wait on a lower-priority thread, which Xcode reports as a hang risk.
    private let queue = DispatchQueue(label: "Encore.AudioPlayer.engine", qos: .default)

    init(offline: Bool) {
        self.offline = offline
        queue.async { [self] in
            if offline, let f = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) {
                try? engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096)
            }
            engine.attach(node)
        }
    }

    func shutdown() {
        queue.async { [self] in
            node.stop()
            engine.stop()
        }
    }

    func setVolume(_ volume: Float) {
        queue.async { [self] in node.volume = volume }
    }

    func setSource(_ newSource: Source, volume: Float) {
        queue.async { [self] in
            let f: AVAudioFormat
            switch newSource {
            case .file(let file): f = file.processingFormat
            case .buffer(let b): f = b.format
            }
            if format != f {
                engine.disconnectNodeOutput(node)
                engine.connect(node, to: engine.mainMixerNode, format: f)
                format = f
            }
            node.volume = volume
            source = newSource
        }
    }

    func play(startFrame: AVAudioFramePosition, frames: AVAudioFrameCount,
              completion: @escaping @MainActor @Sendable () -> Void,
              failure: @escaping @MainActor @Sendable (String) -> Void) {
        queue.async { [self] in
            node.stop()
            guard let format, let source else { return }
            // Offline there is no playback, only rendering.
            let callbackType: AVAudioPlayerNodeCompletionCallbackType = offline ? .dataRendered : .dataPlayedBack
            let done: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { _ in
                Task { @MainActor in completion() }
            }
            switch source {
            case .file(let file):
                node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                                     completionCallbackType: callbackType, completionHandler: done)
            case .buffer(let pcm):
                let available = AVAudioFramePosition(pcm.frameLength) - startFrame
                let count = AVAudioFrameCount(max(0, min(AVAudioFramePosition(frames), available)))
                guard count > 0, let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    Task { @MainActor in completion() }
                    return
                }
                slice.frameLength = count
                slice.floatChannelData![0].update(from: pcm.floatChannelData![0] + Int(startFrame), count: Int(count))
                node.scheduleBuffer(slice, at: nil, options: [], completionCallbackType: callbackType, completionHandler: done)
            }
            do {
                if !engine.isRunning { try engine.start() }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in failure(message) }
                return
            }
            node.play()
        }
    }

    /// Stops the node and pauses the engine; `position` (if given) receives the playhead just before stopping.
    func halt(position: (@MainActor @Sendable (TimeInterval?) -> Void)?) {
        queue.async { [self] in
            let seconds = position == nil ? nil : playhead()
            node.stop()
            if engine.isRunning { engine.pause() }
            if let position { Task { @MainActor in position(seconds) } }
        }
    }

    /// Seconds played in the current segment, or nil when the node hasn't rendered yet.
    func position(_ reply: @escaping @MainActor @Sendable (TimeInterval?) -> Void) {
        queue.async { [self] in
            let seconds = playhead()
            Task { @MainActor in reply(seconds) }
        }
    }

    private func playhead() -> TimeInterval? {
        guard node.isPlaying, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func renderOffline(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { c.resume() }
                guard offline, engine.isRunning,
                      let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                    frameCapacity: engine.manualRenderingMaximumFrameCount) else { return }
                var remaining = AVAudioFrameCount(seconds * engine.manualRenderingFormat.sampleRate)
                while remaining > 0 {
                    let n = min(remaining, buffer.frameCapacity)
                    guard (try? engine.renderOffline(n, to: buffer)) == .success else { return }
                    remaining -= n
                }
            }
        }
    }
}

/// What's playing app-wide, for the global mini-player dock. Holds the most recent player even when paused.
@MainActor @Observable
public final class NowPlaying {
    public static let shared = NowPlaying()
    public private(set) var player: AudioPlayer?

    func willPlay(_ player: AudioPlayer) {
        if let current = self.player, current !== player { current.pause() }
        self.player = player
    }

    /// Hides the dock (and stops playback).
    public func dismiss() {
        player?.stop()
        player = nil
    }
}
