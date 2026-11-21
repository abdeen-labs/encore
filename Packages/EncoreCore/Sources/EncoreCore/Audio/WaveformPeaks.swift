import Accelerate
import Foundation

/// One column of a drawn waveform.
public struct PeakBucket: Sendable, Equatable, Hashable, Codable {
    public var min: Float
    public var max: Float
    public var rms: Float
    public init(min: Float, max: Float, rms: Float) { self.min = min; self.max = max; self.rms = rms }
    public static let zero = PeakBucket(min: 0, max: 0, rms: 0)
}

/// Min/max/RMS summary of audio at a fixed base resolution. Compute it once (from a buffer, or streamed from a
/// file of any length), then call `buckets(count:in:)` for each zoom level — that's cheap (O(base buckets in range)).
public struct WaveformPeaks: Sendable, Equatable, Codable {
    /// Sample rate of the analysed audio.
    public var sampleRate: Double
    /// Source samples per base bucket.
    public var samplesPerBucket: Int
    public var mins: [Float]
    public var maxs: [Float]
    public var rms: [Float]
    /// Duration of the whole source. While a file is still being analysed this is larger than `coveredDuration`.
    public var duration: TimeInterval

    public var count: Int { mins.count }
    public var bucketDuration: TimeInterval { Double(samplesPerBucket) / sampleRate }
    public var coveredDuration: TimeInterval { min(duration, Double(count) * bucketDuration) }
    public var isComplete: Bool { coveredDuration >= duration - bucketDuration }

    public init(sampleRate: Double, samplesPerBucket: Int, mins: [Float] = [], maxs: [Float] = [], rms: [Float] = [],
                duration: TimeInterval) {
        self.sampleRate = sampleRate; self.samplesPerBucket = samplesPerBucket
        self.mins = mins; self.maxs = maxs; self.rms = rms; self.duration = duration
    }

    public subscript(index: Int) -> PeakBucket { PeakBucket(min: mins[index], max: maxs[index], rms: rms[index]) }

    /// Peaks of an in-memory buffer. `samplesPerBucket` defaults to ~5 ms of audio.
    public init(buffer: AudioBuffer, samplesPerBucket: Int? = nil) {
        let spb = Swift.max(1, samplesPerBucket ?? Int((buffer.sampleRate * 0.005).rounded()))
        var acc = PeakAccumulator(samplesPerBucket: spb)
        buffer.samples.withUnsafeBufferPointer { acc.add($0) }
        acc.flush()
        self.init(sampleRate: buffer.sampleRate, samplesPerBucket: spb, mins: acc.mins, maxs: acc.maxs, rms: acc.rms,
                  duration: buffer.duration)
    }

    /// Streams a media file of any length (memory stays bounded by the peaks themselves: ~200 buckets/s).
    /// `onUpdate` receives growing partial results a few times a second, for progressive drawing.
    /// Honours task cancellation.
    public static func compute(fileAt url: URL, bucketsPerSecond: Double = 200,
                               onUpdate: (@Sendable (WaveformPeaks) -> Void)? = nil) async throws -> WaveformPeaks {
        let reader = try await AudioFileReader(url: url)
        let rate = reader.outputSampleRate
        let spb = Swift.max(1, Int((rate / bucketsPerSecond).rounded()))
        var acc = PeakAccumulator(samplesPerBucket: spb)
        let total = reader.info.duration
        var lastUpdate = Date()
        while let chunk = try reader.next() {
            try Task.checkCancellation()
            chunk.withUnsafeBufferPointer { acc.add($0) }
            if let onUpdate, Date().timeIntervalSince(lastUpdate) > 0.2 {
                lastUpdate = Date()
                onUpdate(WaveformPeaks(sampleRate: rate, samplesPerBucket: spb, mins: acc.mins, maxs: acc.maxs,
                                       rms: acc.rms, duration: total))
            }
        }
        acc.flush()
        let covered = Double(acc.mins.count * spb) / rate
        // Trust the decoded length over the header's when they disagree.
        let result = WaveformPeaks(sampleRate: rate, samplesPerBucket: spb, mins: acc.mins, maxs: acc.maxs, rms: acc.rms,
                                   duration: abs(covered - total) > Double(spb) / rate ? covered : total)
        onUpdate?(result)
        return result
    }

    /// `count` display buckets spanning `range` (seconds; the whole duration by default). Each output bucket
    /// combines the base buckets it covers; when zoomed in past the base resolution, buckets repeat.
    public func buckets(count outCount: Int, in range: ClosedRange<TimeInterval>? = nil) -> [PeakBucket] {
        guard outCount > 0 else { return [] }
        let r = range ?? 0...duration
        let span = r.upperBound - r.lowerBound
        guard span > 0, bucketDuration > 0 else { return Array(repeating: .zero, count: outCount) }
        var out = [PeakBucket](); out.reserveCapacity(outCount)
        let startBucket = r.lowerBound / bucketDuration
        let perOut = span / bucketDuration / Double(outCount)
        for b in 0..<outCount {
            let lo = Int((startBucket + Double(b) * perOut).rounded(.down))
            var hi = Int((startBucket + Double(b + 1) * perOut).rounded(.down))
            hi = Swift.max(hi, lo + 1)
            let a = Swift.max(0, lo), z = Swift.min(count, hi)
            guard a < z else { out.append(.zero); continue }
            var mn: Float = 0, mx: Float = 0, sq: Float = 0
            mins.withUnsafeBufferPointer { vDSP_minv($0.baseAddress! + a, 1, &mn, vDSP_Length(z - a)) }
            maxs.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + a, 1, &mx, vDSP_Length(z - a)) }
            rms.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + a, 1, &sq, vDSP_Length(z - a)) }
            out.append(PeakBucket(min: mn, max: mx, rms: sq.squareRoot()))
        }
        return out
    }
}

/// Accumulates min/max/sum-of-squares into fixed-size buckets across chunk boundaries.
struct PeakAccumulator {
    let samplesPerBucket: Int
    var mins: [Float] = [], maxs: [Float] = [], rms: [Float] = []
    private var curMin: Float = .infinity, curMax: Float = -.infinity, curSq: Float = 0, curCount = 0

    init(samplesPerBucket: Int) { self.samplesPerBucket = samplesPerBucket }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        var i = 0
        let n = samples.count
        while i < n {
            let take = Swift.min(samplesPerBucket - curCount, n - i)
            var mn: Float = 0, mx: Float = 0, sq: Float = 0
            vDSP_minv(base + i, 1, &mn, vDSP_Length(take))
            vDSP_maxv(base + i, 1, &mx, vDSP_Length(take))
            vDSP_svesq(base + i, 1, &sq, vDSP_Length(take))
            curMin = Swift.min(curMin, mn); curMax = Swift.max(curMax, mx); curSq += sq; curCount += take
            i += take
            if curCount == samplesPerBucket { emit() }
        }
    }

    mutating func flush() { if curCount > 0 { emit() } }

    private mutating func emit() {
        mins.append(curMin); maxs.append(curMax); rms.append((curSq / Float(curCount)).squareRoot())
        curMin = .infinity; curMax = -.infinity; curSq = 0; curCount = 0
    }
}
