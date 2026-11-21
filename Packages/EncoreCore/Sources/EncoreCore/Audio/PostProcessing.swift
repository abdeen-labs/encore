import Accelerate
import Foundation

/// Short-time energy of a signal: RMS level in dBFS per 10 ms frame. Shared by silence removal and segmentation.
struct EnergyEnvelope {
    static let frameDuration: TimeInterval = 0.01
    let frameLength: Int
    let sampleRate: Double
    /// dBFS per frame (−∞ for digital silence); RMS where a full-scale sine reads −3 dB.
    var levels: [Double] = []
    private var sq: Float = 0
    private var n = 0
    private(set) var sampleCount = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int((sampleRate * Self.frameDuration).rounded()))
    }

    init(buffer: AudioBuffer) {
        self.init(sampleRate: buffer.sampleRate)
        buffer.samples.withUnsafeBufferPointer { add($0) }
        flush()
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        sampleCount += samples.count
        var i = 0
        while i < samples.count {
            let take = min(frameLength - n, samples.count - i)
            var s: Float = 0
            vDSP_svesq(base + i, 1, &s, vDSP_Length(take))
            sq += s; n += take; i += take
            if n == frameLength { emit() }
        }
    }

    mutating func flush() { if n > 0 { emit() } }

    private mutating func emit() {
        levels.append(AudioMath.decibels(Double((sq / Float(n)).squareRoot())))
        sq = 0; n = 0
    }

    func time(ofFrame i: Int) -> TimeInterval { Double(i * frameLength) / sampleRate }
    func sample(ofFrame i: Int) -> Int { min(sampleCount, i * frameLength) }

    /// Level below which a frame counts as silence. Adapts to the material: well under the speech level,
    /// but above a steady noise floor.
    func silenceThreshold(override: Double? = nil) -> Double {
        if let override { return override }
        let finite = levels.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return -60 }
        func pct(_ p: Double) -> Double { finite[min(finite.count - 1, Int(p * Double(finite.count - 1)))] }
        let speech = pct(0.95)
        // Digital silence doesn't show up in `finite`; treat it as an infinitely low floor.
        let floor = finite.count < levels.count / 10 * 9 ? -Double.infinity : pct(0.10)
        return min(speech - 20, max(speech - 45, floor + 8))
    }

    /// Runs of consecutive silent frames, as half-open frame ranges.
    func silentRuns(threshold: Double) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, level) in levels.enumerated() {
            if level <= threshold { if start == nil { start = i } }
            else if let s = start { runs.append(s..<i); start = nil }
        }
        if let s = start { runs.append(s..<levels.count) }
        return runs
    }
}

public struct SilenceRemovalOptions: Sendable, Hashable, Codable {
    /// Internal silences longer than this are shortened to it.
    public var maxSilence: TimeInterval = 0.6
    /// Silence kept before the first and after the last sound.
    public var edgePadding: TimeInterval = 0.08
    /// Frames at or below this level (dBFS RMS) are silence. nil picks a level from the material.
    public var thresholdDB: Double?
    /// Crossfade used where silence is cut out.
    public var crossfade: TimeInterval = 0.01
    public init(maxSilence: TimeInterval = 0.6, edgePadding: TimeInterval = 0.08, thresholdDB: Double? = nil) {
        self.maxSilence = maxSilence; self.edgePadding = edgePadding; self.thresholdDB = thresholdDB
    }
}

public enum PostProcessor {
    /// Applies `PostProcessingOptions` in the right order: silence removal, then loudness normalisation
    /// (with a true-peak ceiling so it never clips).
    public static func apply(_ options: PostProcessingOptions, to buffer: AudioBuffer,
                             truePeakCeiling: Double = Loudness.defaultTruePeakCeiling) -> AudioBuffer {
        var out = buffer
        if options.removeSilence {
            out = removeSilence(out, options: SilenceRemovalOptions(maxSilence: options.maxSilenceSeconds))
        }
        if options.normalizeLoudness {
            out = Loudness.normalize(out, targetLUFS: options.targetLUFS, truePeakCeiling: truePeakCeiling).0
        }
        return out
    }

    /// Trims leading/trailing silence (keeping `edgePadding`) and shortens internal silences longer than
    /// `maxSilence` to exactly that, joining the halves with a short equal-power crossfade so there are no clicks.
    /// Audio with no detectable sound is returned unchanged.
    public static func removeSilence(_ buffer: AudioBuffer, options: SilenceRemovalOptions = SilenceRemovalOptions()) -> AudioBuffer {
        guard !buffer.isEmpty else { return buffer }
        let env = EnergyEnvelope(buffer: buffer)
        let threshold = env.silenceThreshold(override: options.thresholdDB)
        let runs = env.silentRuns(threshold: threshold)
        guard let firstSound = env.levels.firstIndex(where: { $0 > threshold }),
              let lastSound = env.levels.lastIndex(where: { $0 > threshold }) else { return buffer }

        let rate = buffer.sampleRate
        let pad = Int(options.edgePadding * rate)
        let start = max(0, env.sample(ofFrame: firstSound) - pad)
        let end = min(buffer.samples.count, env.sample(ofFrame: lastSound + 1) + pad)
        let maxGap = max(0, Int(options.maxSilence * rate))
        let fade = max(2, Int(options.crossfade * rate))

        // Pieces to keep, as sample ranges, between internal gaps that are too long.
        var keep: [Range<Int>] = []
        var cursor = start
        for run in runs where run.lowerBound > firstSound && run.upperBound <= lastSound {
            let gapStart = env.sample(ofFrame: run.lowerBound), gapEnd = env.sample(ofFrame: run.upperBound)
            guard gapEnd - gapStart > maxGap + fade else { continue }
            // Keep half the allowed gap after the sound and half before the next, plus the crossfade overlap.
            let headEnd = gapStart + maxGap / 2 + fade / 2
            let tailStart = gapEnd - (maxGap - maxGap / 2) - (fade - fade / 2)
            keep.append(cursor..<headEnd)
            cursor = tailStart
        }
        keep.append(cursor..<end)

        let pieces = keep.map { AudioBuffer(samples: Array(buffer.samples[$0]), sampleRate: rate) }
        var out = (try? AudioEdit.concatenate(pieces, crossfade: (Double(fade) + 0.5) / rate, curve: .equalPower))
            ?? AudioBuffer(samples: Array(buffer.samples[start..<end]), sampleRate: rate)
        // Fade the outer edges only when we actually cut into non-silent material.
        AudioEdit.applyFades(&out.samples, fadeIn: start > 0 ? min(fade, pad) : 0,
                             fadeOut: end < buffer.samples.count ? min(fade, pad) : 0)
        return out
    }
}
