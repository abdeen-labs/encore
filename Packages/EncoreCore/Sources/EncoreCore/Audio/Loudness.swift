import Accelerate
import Foundation

/// Loudness per ITU-R BS.1770-4 / EBU R128 for a mono signal (channel weight 1.0; a mono file is
/// measured as one channel, like ffmpeg's `ebur128` without `dualmono`).
public struct LoudnessMeasurement: Sendable, Codable, Equatable {
    /// Gated integrated loudness, LUFS. −∞ when everything is below the absolute gate (or shorter than 400 ms).
    public var integrated: Double
    /// Loudness range (EBU Tech 3342), LU.
    public var loudnessRange: Double
    /// Highest momentary (400 ms) loudness, LUFS.
    public var maxMomentary: Double
    /// Highest short-term (3 s) loudness, LUFS.
    public var maxShortTerm: Double
    /// True peak (oversampled), dBTP.
    public var truePeak: Double
    /// Sample peak, dBFS.
    public var samplePeak: Double
    public var duration: TimeInterval
}

public enum Loudness {
    /// Default true-peak ceiling for normalisation, dBTP (EBU R128 / common streaming practice).
    public static let defaultTruePeakCeiling: Double = -1

    public static func measure(_ buffer: AudioBuffer) -> LoudnessMeasurement {
        let meter = LoudnessMeter(sampleRate: buffer.sampleRate)
        meter.process(buffer.samples)
        return meter.result
    }

    public static func integratedLoudness(_ buffer: AudioBuffer) -> Double {
        let meter = LoudnessMeter(sampleRate: buffer.sampleRate, measureTruePeak: false)
        meter.process(buffer.samples)
        return meter.integrated
    }

    /// True peak in dBTP.
    public static func truePeak(_ buffer: AudioBuffer) -> Double {
        let meter = TruePeakMeter(sampleRate: buffer.sampleRate)
        meter.process(buffer.samples)
        return AudioMath.decibels(Double(meter.peak))
    }

    /// Streams a file of any length through the meter.
    public static func measure(fileAt url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoudnessMeasurement {
        let reader = try await AudioFileReader(url: url)
        let meter = LoudnessMeter(sampleRate: reader.outputSampleRate)
        let total = Double(max(1, reader.expectedFrameCount ?? 1))
        var done = 0
        while let chunk = try reader.next() {
            try Task.checkCancellation()
            meter.process(chunk)
            done += chunk.count
            progress?(min(1, Double(done) / total))
        }
        return meter.result
    }

    public struct NormalizationReport: Sendable, Codable, Equatable {
        public var inputLUFS: Double
        public var outputLUFS: Double
        public var outputTruePeak: Double
        /// Overall gain applied, dB.
        public var gainDB: Double
        /// Largest gain reduction the peak limiter applied, dB (0 when it wasn't needed).
        public var limiterReductionDB: Double
    }

    /// Normalises to `targetLUFS` (integrated) without letting the true peak exceed `truePeakCeiling`.
    ///
    /// When reaching the target would push peaks over the ceiling, a look-ahead limiter shaves just those peaks.
    /// Brief transients can be limited as hard as needed; what's capped is the limiter's audible cost, measured as
    /// the loudness it takes away (`maxLimiterLossLU`). If the target would cost more than that, the gain is
    /// lowered until it doesn't, so the result lands below the target rather than sounding squashed.
    /// Silent input is returned unchanged.
    public static func normalize(_ buffer: AudioBuffer, targetLUFS: Double,
                                 truePeakCeiling: Double = defaultTruePeakCeiling,
                                 maxLimiterLossLU: Double = 1) -> (AudioBuffer, NormalizationReport) {
        let input = measure(buffer)
        guard input.integrated.isFinite, input.truePeak.isFinite else {
            return (buffer, NormalizationReport(inputLUFS: input.integrated, outputLUFS: input.integrated,
                                                outputTruePeak: input.truePeak, gainDB: 0, limiterReductionDB: 0))
        }
        // True-peak meters differ by a few hundredths of a dB (interpolation filters), so aim a little under.
        let safeCeiling = truePeakCeiling - 0.05
        let limiterCeiling = truePeakCeiling - 0.1
        /// Gain then limit, always from the original input so passes don't compound.
        func attempt(_ gain: Double) -> (audio: AudioBuffer, reduction: Double, lufs: Double) {
            var out = AudioEdit.gain(buffer, decibels: gain)
            let reduction = PeakLimiter.limit(&out.samples, sampleRate: out.sampleRate, ceilingDB: limiterCeiling)
            return (out, reduction, reduction > 0 ? integratedLoudness(out) : input.integrated + gain)
        }
        func loss(_ gain: Double, _ r: (audio: AudioBuffer, reduction: Double, lufs: Double)) -> Double {
            input.integrated + gain - r.lufs
        }

        var gainDB = targetLUFS - input.integrated
        var result: (audio: AudioBuffer, reduction: Double, lufs: Double)
        if input.truePeak + gainDB <= safeCeiling {
            result = (AudioEdit.gain(buffer, decibels: gainDB), 0, input.integrated + gainDB)
        } else {
            result = attempt(gainDB)
            if loss(gainDB, result) <= maxLimiterLossLU {
                // Make up what the limiter took, while that stays within budget.
                for _ in 0..<3 {
                    let shortfall = targetLUFS - result.lufs
                    guard shortfall > 0.05 else { break }
                    let next = attempt(gainDB + shortfall)
                    guard loss(gainDB + shortfall, next) <= maxLimiterLossLU else { break }
                    gainDB += shortfall
                    result = next
                }
            } else {
                // Too costly: find the largest gain whose limiting stays within budget.
                var lo = min(gainDB, safeCeiling - input.truePeak), hi = gainDB
                var best = attempt(lo)
                for _ in 0..<7 where hi - lo > 0.1 {
                    let mid = (lo + hi) / 2
                    let r = attempt(mid)
                    if loss(mid, r) <= maxLimiterLossLU { lo = mid; best = r } else { hi = mid }
                }
                gainDB = lo
                result = best
            }
        }
        var out = result.audio
        // Hard guarantee: whatever the limiter left, the true peak ends up at or below the ceiling.
        var peak = truePeak(out)
        if peak > safeCeiling {
            let trim = safeCeiling - peak
            out = AudioEdit.gain(out, decibels: trim)
            gainDB += trim
            peak = truePeak(out)
        }
        let report = NormalizationReport(inputLUFS: input.integrated, outputLUFS: integratedLoudness(out),
                                         outputTruePeak: peak, gainDB: gainDB, limiterReductionDB: result.reduction)
        return (out, report)
    }
}

// MARK: - Meter

/// Streaming BS.1770 meter. Feed it chunks with `process`, read `result` at the end.
public final class LoudnessMeter {
    public let sampleRate: Double
    private var delay = [Double](repeating: 0, count: 6)
    private let coefficients: [Double]
    private let subBlockLength: Int
    private var subBlockSum = 0.0
    private var subBlockCount = 0
    /// Mean square of each completed 100 ms sub-block after K-weighting.
    private var subBlocks: [Double] = []
    private var scratch: [Double] = []
    private let truePeakMeter: TruePeakMeter?
    private var samplePeak: Float = 0
    private var frames = 0

    public init(sampleRate: Double, measureTruePeak: Bool = true) {
        self.sampleRate = sampleRate
        coefficients = Self.kWeighting(sampleRate: sampleRate)
        subBlockLength = max(1, Int((sampleRate * 0.1).rounded()))
        truePeakMeter = measureTruePeak ? TruePeakMeter(sampleRate: sampleRate) : nil
    }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let n = samples.count
        guard n > 0 else { return }
        frames += n
        var peak: Float = 0
        vDSP_maxmgv(samples.baseAddress!, 1, &peak, vDSP_Length(n))
        samplePeak = max(samplePeak, peak)
        truePeakMeter?.process(samples)

        if scratch.count < n { scratch = [Double](repeating: 0, count: n) }
        var filtered = [Double](repeating: 0, count: n)
        scratch.withUnsafeMutableBufferPointer { s in
            vDSP_vspdp(samples.baseAddress!, 1, s.baseAddress!, 1, vDSP_Length(n))
            // Two biquads in series: high-shelf "head" filter, then the RLB high-pass.
            coefficients.withUnsafeBufferPointer { c in
                if let setup = vDSP_biquad_CreateSetupD(c.baseAddress!, 2) {
                    vDSP_biquadD(setup, &delay, s.baseAddress!, 1, &filtered, 1, vDSP_Length(n))
                    vDSP_biquad_DestroySetupD(setup)
                }
            }
        }
        // Accumulate squares into 100 ms sub-blocks.
        var i = 0
        filtered.withUnsafeBufferPointer { f in
            while i < n {
                let take = min(subBlockLength - subBlockCount, n - i)
                var sum = 0.0
                vDSP_svesqD(f.baseAddress! + i, 1, &sum, vDSP_Length(take))
                subBlockSum += sum
                subBlockCount += take
                i += take
                if subBlockCount == subBlockLength {
                    subBlocks.append(subBlockSum / Double(subBlockLength))
                    subBlockSum = 0
                    subBlockCount = 0
                }
            }
        }
    }

    /// Gated integrated loudness so far.
    public var integrated: Double { Self.gatedLoudness(blocks: blockPowers(subBlocksPerBlock: 4), relativeGate: -10) }

    public var result: LoudnessMeasurement {
        let momentary = blockPowers(subBlocksPerBlock: 4)
        let shortTerm = blockPowers(subBlocksPerBlock: 30)
        return LoudnessMeasurement(
            integrated: Self.gatedLoudness(blocks: momentary, relativeGate: -10),
            loudnessRange: Self.loudnessRange(shortTerm),
            maxMomentary: momentary.map(Self.lufs).max() ?? -.infinity,
            maxShortTerm: shortTerm.map(Self.lufs).max() ?? -.infinity,
            truePeak: AudioMath.decibels(Double(max(truePeakMeter?.peak ?? 0, samplePeak))),
            samplePeak: AudioMath.decibels(Double(samplePeak)),
            duration: Double(frames) / sampleRate)
    }

    // MARK: Internals

    /// Mean square of each sliding window of `subBlocksPerBlock` sub-blocks, stepping one sub-block (100 ms)
    /// at a time: 400 ms blocks with 75 % overlap for momentary, 3 s for short-term.
    private func blockPowers(subBlocksPerBlock k: Int) -> [Double] {
        guard subBlocks.count >= k else { return [] }
        var out = [Double](); out.reserveCapacity(subBlocks.count - k + 1)
        var running = subBlocks[0..<k].reduce(0, +)
        out.append(running / Double(k))
        for i in k..<subBlocks.count {
            running += subBlocks[i] - subBlocks[i - k]
            out.append(max(0, running) / Double(k))
        }
        return out
    }

    static func lufs(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -.infinity }

    /// Absolute gate at −70 LUFS, then a relative gate `relativeGate` LU below the loudness of the survivors.
    static func gatedLoudness(blocks: [Double], relativeGate: Double) -> Double {
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let threshold = lufs(absolute.reduce(0, +) / Double(absolute.count)) + relativeGate
        let gated = absolute.filter { lufs($0) > threshold }
        guard !gated.isEmpty else { return -.infinity }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// EBU Tech 3342: short-term values gated at −70 LUFS and −20 LU relative; spread between the 10th
    /// and 95th percentiles.
    static func loudnessRange(_ shortTerm: [Double]) -> Double {
        let absolute = shortTerm.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return 0 }
        let threshold = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 20
        let values = absolute.map(lufs).filter { $0 > threshold }.sorted()
        guard values.count > 1 else { return 0 }
        func percentile(_ p: Double) -> Double {
            let pos = p * Double(values.count - 1)
            let lo = Int(pos.rounded(.down)), hi = min(values.count - 1, lo + 1)
            return values[lo] + (values[hi] - values[lo]) * (pos - Double(lo))
        }
        return percentile(0.95) - percentile(0.10)
    }

    /// The BS.1770 K-weighting pre-filter, recomputed for any sample rate (same derivation as libebur128).
    /// Returns two biquad sections as [b0, b1, b2, a1, a2] each.
    static func kWeighting(sampleRate fs: Double) -> [Double] {
        // Stage 1: high shelf (+4 dB above ~1.7 kHz) modelling the head.
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        // Stage 2: RLB high-pass at ~38 Hz.
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        return shelf + highPass
    }
}

// MARK: - True peak

/// Streaming true-peak meter: polyphase windowed-sinc oversampling to ≥ 192 kHz (4× at 48 kHz, as
/// BS.1770-4 Annex 2 asks; 8× at 24 kHz and below).
public final class TruePeakMeter {
    public let factor: Int
    public private(set) var peak: Float = 0
    /// phases[k][j]: coefficient for output phase k applied to input x[n - j].
    let phases: [[Float]]
    let taps: Int
    private var history: [Float]

    public init(sampleRate: Double) {
        factor = sampleRate >= 192_000 ? 1 : Int((192_000 / sampleRate).rounded(.up)).clamped(to: 2...8)
        taps = 32
        phases = Self.design(factor: factor, tapsPerPhase: taps)
        history = [Float](repeating: 0, count: taps - 1)
    }

    public func process(_ samples: [Float]) { samples.withUnsafeBufferPointer { process($0) } }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0 else { return }
        var p: Float = 0
        vDSP_maxmgv(samples.baseAddress!, 1, &p, vDSP_Length(samples.count))
        peak = max(peak, p)
        guard factor > 1 else { return }
        let ext = history + Array(samples)
        var out = [Float](repeating: 0, count: samples.count)
        for phase in phases {
            phase.withUnsafeBufferPointer { h in
                vDSP_conv(ext, 1, h.baseAddress! + (taps - 1), -1, &out, 1, vDSP_Length(samples.count), vDSP_Length(taps))
            }
            vDSP_maxmgv(out, 1, &p, vDSP_Length(out.count))
            peak = max(peak, p)
        }
        history = Array(ext.suffix(taps - 1))
    }

    /// Per-sample true-peak magnitude (max over the oversampled points near each sample), for limiting.
    static func envelope(_ samples: [Float], sampleRate: Double) -> [Float] {
        var env = samples.map { abs($0) }
        let meter = TruePeakMeter(sampleRate: sampleRate)
        guard meter.factor > 1, !samples.isEmpty else { return env }
        let taps = meter.taps
        // Pad so the filter's group delay (≈ taps/2 input samples) can be re-aligned.
        let delay = taps / 2
        let ext = [Float](repeating: 0, count: taps - 1) + samples + [Float](repeating: 0, count: delay)
        let n = samples.count + delay
        var out = [Float](repeating: 0, count: n)
        for phase in meter.phases {
            phase.withUnsafeBufferPointer { h in
                vDSP_conv(ext, 1, h.baseAddress! + (taps - 1), -1, &out, 1, vDSP_Length(n), vDSP_Length(taps))
            }
            vDSP_vabs(out, 1, &out, 1, vDSP_Length(n))
            for i in 0..<samples.count {
                // Output index i + delay corresponds (within half a sample) to input index i; cover both neighbours.
                let a = out[i + delay], b = out[max(0, i + delay - 1)]
                env[i] = max(env[i], max(a, b))
            }
        }
        return env
    }

    static func design(factor: Int, tapsPerPhase: Int) -> [[Float]] {
        guard factor > 1 else { return [[1]] }
        let n = factor * tapsPerPhase
        let beta = 8.0
        let center = Double(n - 1) / 2
        var h = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = (Double(i) - center) / Double(factor)
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let r = 2 * Double(i) / Double(n - 1) - 1
            h[i] = sinc * besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta)
        }
        return (0..<factor).map { k in
            let coeffs = stride(from: k, to: n, by: factor).map { h[$0] }
            // Normalise each phase to unity DC gain so a constant signal reads exactly its level.
            let sum = coeffs.reduce(0, +)
            return coeffs.map { Float($0 / sum) }
        }
    }

    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0, k = 1.0
        while term > 1e-12 * sum {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            k += 1
        }
        return sum
    }
}

// MARK: - Limiter

enum PeakLimiter {
    /// Look-ahead true-peak limiter (5 ms attack, 80 ms release). Returns the largest reduction applied, dB.
    @discardableResult
    static func limit(_ samples: inout [Float], sampleRate: Double, ceilingDB: Double) -> Double {
        let ceiling = Float(AudioMath.amplitude(decibels: ceilingDB))
        let env = TruePeakMeter.envelope(samples, sampleRate: sampleRate)
        guard let maxEnv = env.max(), maxEnv > ceiling else { return 0 }
        let n = samples.count
        let lookahead = max(1, Int(0.005 * sampleRate))
        // Required gain per sample.
        var required = [Float](repeating: 1, count: n)
        for i in 0..<n where env[i] > ceiling { required[i] = ceiling / env[i] }
        // m[j] = min(required[j ... j+L]) — forward-looking minimum (monotonic deque).
        var forwardMin = [Float](repeating: 1, count: n)
        var deque = [Int](); deque.reserveCapacity(lookahead + 2)
        var head = 0
        for j in stride(from: n - 1, through: 0, by: -1) {
            // Window [j, j+L]; add j, drop indices > j+L.
            while deque.count > head, required[deque[deque.count - 1]] >= required[j] { deque.removeLast() }
            deque.append(j)
            if head > deque.count - 1 { head = deque.count - 1 }
            while deque[head] > j + lookahead { head += 1 }
            forwardMin[j] = required[deque[head]]
            if head > 4096 { deque.removeFirst(head); head = 0 }
        }
        // Release: recover exponentially, never above the forward minimum.
        let release = Float(1 - exp(-1 / (0.08 * sampleRate)))
        var g: Float = 1
        for j in 0..<n {
            g = min(forwardMin[j], g + (1 - g) * release)
            forwardMin[j] = g
        }
        // Smooth the attack with a box filter over the look-ahead window: G[n] = mean(m[n-L ... n]) ≤ required[n].
        var gain = [Float](repeating: 1, count: n)
        var sum: Double = Double(lookahead + 1) // entries before the start count as 1
        var window = [Float](repeating: 1, count: lookahead + 1)
        var w = 0
        var minGain: Float = 1
        for i in 0..<n {
            sum += Double(forwardMin[i]) - Double(window[w])
            window[w] = forwardMin[i]
            w = (w + 1) % (lookahead + 1)
            gain[i] = Float(sum / Double(lookahead + 1))
            minGain = min(minGain, gain[i])
        }
        vDSP_vmul(samples, 1, gain, 1, &samples, 1, vDSP_Length(n))
        return -AudioMath.decibels(Double(minGain))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
