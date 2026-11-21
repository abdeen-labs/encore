@preconcurrency import AVFoundation
import Foundation
import Observation

/// Plays one file or buffer. Bind SwiftUI views to its properties; `currentTime` updates ~30× a second while
/// playing. Only one player plays at a time: starting one pauses whatever `NowPlaying.shared` had.
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
    public var volume: Float = 1 { didSet { node.volume = volume } }
    public private(set) var lastError: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var pcm: AVAudioPCMBuffer?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var segmentStart: TimeInterval = 0
    @ObservationIgnored private var segmentEnd: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var temporaryFile: URL?

    public init(title: String? = nil) {
        self.title = title
        engine.attach(node)
    }

    isolated deinit {
        ticker?.cancel()
        engine.stop()
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
        configure(format: playable.processingFormat)
        file = playable
        pcm = nil
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
        configure(format: fmt)
        pcm = b
        file = nil
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
        currentTime = playheadTime()
        halt()
    }

    public func toggle() { isPlaying ? pause() : play() }

    /// Stops and rewinds.
    public func stop() {
        halt()
        currentTime = activeRange?.lowerBound ?? 0
        activeRange = nil
    }

    public func seek(to time: TimeInterval) {
        let t = min(max(0, time), duration)
        if let r = activeRange, !r.contains(t) { activeRange = nil }
        if isPlaying {
            start(from: t, to: activeRange?.upperBound ?? duration)
        } else {
            currentTime = t
        }
    }

    // MARK: Internals

    private func configure(format: AVAudioFormat) {
        if self.format != format {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        node.volume = volume
    }

    private func start(from: TimeInterval, to: TimeInterval) {
        guard isLoaded, let format, to > from else { return }
        NowPlaying.shared.willPlay(self)
        generation += 1
        let gen = generation
        node.stop()
        let rate = format.sampleRate
        let startFrame = AVAudioFramePosition((from * rate).rounded())
        let endFrame = AVAudioFramePosition((to * rate).rounded())
        let frames = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frames > 0 else { return }
        let done = Self.completion { [weak self] in self?.finished(generation: gen) }
        if let file {
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                                 completionCallbackType: .dataPlayedBack, completionHandler: done)
        } else if let pcm, let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            slice.frameLength = frames
            slice.floatChannelData![0].update(from: pcm.floatChannelData![0] + Int(startFrame), count: Int(frames))
            node.scheduleBuffer(slice, at: nil, options: [], completionCallbackType: .dataPlayedBack, completionHandler: done)
        } else {
            return
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            lastError = AudioError.playbackFailed(error.localizedDescription).localizedDescription
            return
        }
        segmentStart = from
        segmentEnd = to
        currentTime = from
        node.play()
        isPlaying = true
        lastError = nil
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying else { return }
                self.currentTime = self.playheadTime()
            }
        }
    }

    private func halt() {
        generation += 1
        ticker?.cancel()
        ticker = nil
        node.stop()
        if engine.isRunning { engine.pause() }
        isPlaying = false
    }

    private func playheadTime() -> TimeInterval {
        guard let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return currentTime
        }
        return min(segmentEnd, segmentStart + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate))
    }

    /// Built outside the main actor: AVAudioPlayerNode calls it on its own thread.
    private nonisolated static func completion(_ body: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in Task { @MainActor in body() } }
    }

    private func finished(generation gen: Int) {
        guard gen == generation else { return }
        halt()
        currentTime = activeRange?.lowerBound ?? 0
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
