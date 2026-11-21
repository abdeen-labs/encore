@preconcurrency import AVFoundation
import Accelerate
import Foundation
import Observation

/// Microphone capture to a mono WAV (32-bit float, at the input device's rate) with live metering.
@MainActor @Observable
public final class AudioRecorder {
    public enum Permission: Sendable, Equatable { case undetermined, granted, denied }
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case finished(URL)
        case failed(String)
    }

    public private(set) var permission: Permission
    public private(set) var state: State = .idle
    public private(set) var elapsed: TimeInterval = 0
    /// RMS level of the last ~50 ms, dBFS (−160 when silent).
    public private(set) var level: Float = -160
    /// Peak of the last ~50 ms, dBFS.
    public private(set) var peak: Float = -160
    /// Recent RMS levels mapped to 0…1 (−60 dBFS → 0), oldest first, for a scrolling live meter.
    public private(set) var recentLevels: [Float] = []
    /// How many entries `recentLevels` keeps.
    public var historyLength = 200
    /// Stop automatically after this long.
    public var maxDuration: TimeInterval?

    public var isRecording: Bool { state == .recording }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var sink: RecordingSink?
    @ObservationIgnored private var url: URL?

    public init() { permission = Self.currentPermission() }

    public static func currentPermission() -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    public func refreshPermission() { permission = Self.currentPermission() }

    /// Shows the system prompt if the user hasn't decided yet.
    @discardableResult
    public func requestPermission() async -> Bool {
        if Self.currentPermission() == .undetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refreshPermission()
        return permission == .granted
    }

    /// Starts recording to `url` (a new scratch file by default).
    public func start(to destination: URL? = nil) async throws {
        guard !isRecording else { return }
        guard await requestPermission() else {
            state = .failed(AudioError.microphonePermissionDenied.localizedDescription)
            throw AudioError.microphonePermissionDenied
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .failed("No audio input device.")
            throw AudioError.recordingFailed("No audio input device is available.")
        }
        let url = destination ?? EncorePaths.scratch.appendingPathComponent("Recording-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, sampleRate: format.sampleRate, encoding: .float32)
        let sink = RecordingSink(writer: writer, sampleRate: format.sampleRate)
        sink.onLevels = { [weak self] rms, peak, frames in
            Task { @MainActor in self?.update(rms: rms, peak: peak, frames: frames) }
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tapBlock(sink))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? writer.finish()
            try? FileManager.default.removeItem(at: url)
            state = .failed(error.localizedDescription)
            throw AudioError.recordingFailed(error.localizedDescription)
        }
        self.engine = engine
        self.sink = sink
        self.url = url
        elapsed = 0
        recentLevels = []
        state = .recording
    }

    /// Stops and returns the finished file.
    @discardableResult
    public func stop() -> URL? {
        guard isRecording, let engine, let sink, let url else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.close()
        self.engine = nil
        self.sink = nil
        level = -160; peak = -160
        if let error = sink.error {
            state = .failed(error)
            return nil
        }
        state = .finished(url)
        return url
    }

    /// Stops and deletes what was recorded.
    public func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
        state = .idle
    }

    /// Built outside the main actor: the tap runs on an audio thread.
    private nonisolated static func tapBlock(_ sink: RecordingSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.consume(buffer) }
    }

    private func update(rms: Float, peak: Float, frames: Int) {
        guard isRecording, let sink else { return }
        level = rms
        self.peak = peak
        elapsed = Double(frames) / sink.sampleRate
        recentLevels.append(max(0, min(1, (rms + 60) / 60)))
        if recentLevels.count > historyLength { recentLevels.removeFirst(recentLevels.count - historyLength) }
        if let maxDuration, elapsed >= maxDuration { stop() }
    }
}

/// Runs on the audio tap thread: mixes to mono, writes, meters.
final class RecordingSink: @unchecked Sendable {
    let writer: WAVWriter
    let sampleRate: Double
    var onLevels: (@Sendable (Float, Float, Int) -> Void)?
    private let lock = NSLock()
    private var closed = false
    private(set) var error: String?
    private var frames = 0
    private var meterSq: Float = 0, meterPeak: Float = 0, meterCount = 0

    init(writer: WAVWriter, sampleRate: Double) { self.writer = writer; self.sampleRate = sampleRate }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let data = buffer.floatChannelData else { return }
        var mono: [Float] = []
        mono.reserveCapacity(n)
        if buffer.format.isInterleaved {
            AudioMath.mixdown(interleaved: data[0], frames: n, channels: Int(buffer.format.channelCount), into: &mono)
        } else {
            AudioMath.mixdown(channels: (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) },
                              frames: n, into: &mono)
        }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do { try writer.append(mono) } catch { self.error = error.localizedDescription }
        frames += n
        var sq: Float = 0, pk: Float = 0
        vDSP_svesq(mono, 1, &sq, vDSP_Length(n))
        vDSP_maxmgv(mono, 1, &pk, vDSP_Length(n))
        meterSq += sq; meterPeak = max(meterPeak, pk); meterCount += n
        if Double(meterCount) >= sampleRate * 0.05 {
            let rms = Float(AudioMath.decibels(Double((meterSq / Float(meterCount)).squareRoot())))
            let peak = Float(AudioMath.decibels(Double(meterPeak)))
            onLevels?(max(-160, rms), max(-160, peak), frames)
            meterSq = 0; meterPeak = 0; meterCount = 0
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        do { try writer.finish() } catch { self.error = error.localizedDescription }
    }
}
