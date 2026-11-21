import Foundation

extension WaveformPeaks {
    /// The best `length`-second stretch to offer as a cloning reference: the window with the most continuous,
    /// healthy-level speech and no clipping, its edges nudged into nearby quiet moments so no word is cut.
    /// Recordings shorter than `length` come back whole. Cheap: works on the peaks, not the audio.
    public func suggestedSelection(length: TimeInterval) -> ClosedRange<TimeInterval> {
        let total = duration
        guard total > length, count > 0, length > 0 else { return 0...max(0, total) }
        // ~50 ms frames.
        let per = max(1, Int((0.05 / bucketDuration).rounded()))
        let frameTime = Double(per) * bucketDuration
        var level: [Double] = [], clipped: [Bool] = []
        level.reserveCapacity(count / per + 1)
        var i = 0
        while i < count {
            let z = min(count, i + per)
            var sq = 0.0
            var peak: Float = 0
            for k in i..<z {
                sq += Double(rms[k]) * Double(rms[k])
                peak = max(peak, max(abs(mins[k]), abs(maxs[k])))
            }
            level.append(AudioMath.decibels((sq / Double(z - i)).squareRoot()))
            clipped.append(peak >= 0.99)
            i = z
        }
        let finite = level.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return 0...length }
        let loud = finite[Int(Double(finite.count - 1) * 0.95)]
        let voicedFloor = max(loud - 30, -55)
        let n = level.count
        let w = max(1, min(n, Int((length / frameTime).rounded())))
        // Prefix sums: voiced frames, clipped frames, voiced level relative to the loud level.
        var voiced = [Double](repeating: 0, count: n + 1), clip = voiced, sum = voiced
        for k in 0..<n {
            let v = level[k] > voicedFloor
            voiced[k + 1] = voiced[k] + (v ? 1 : 0)
            clip[k + 1] = clip[k] + (clipped[k] ? 1 : 0)
            sum[k + 1] = sum[k] + (v ? level[k] - loud : 0)
        }
        var best = (start: 0, score: -Double.infinity)
        for s in 0...(n - w) {
            let v = voiced[s + w] - voiced[s]
            let voicedFraction = v / Double(w)
            let clipFraction = (clip[s + w] - clip[s]) / Double(w)
            let meanRelative = v > 0 ? (sum[s + w] - sum[s]) / v : -60
            let score = voicedFraction - 4 * clipFraction + 0.004 * meanRelative
            if score > best.score + 1e-9 { best = (s, score) }
        }
        // Nudge each edge to the quietest frame nearby, leaning outwards so speech isn't clipped.
        func quietest(_ range: ClosedRange<Int>) -> Int {
            let lo = max(0, range.lowerBound), hi = min(n - 1, range.upperBound)
            guard lo <= hi else { return min(max(range.lowerBound, 0), n - 1) }
            func value(_ k: Int) -> Double { level[k].isFinite ? level[k] : -200 }
            return (lo...hi).min { value($0) < value($1) } ?? lo
        }
        let slack = max(1, Int((0.5 / frameTime).rounded()))
        let startFrame = quietest((best.start - slack)...(best.start + slack / 2))
        let endFrame = quietest((best.start + w - 1 - slack / 2)...(best.start + w - 1 + slack))
        let start = Double(startFrame) * frameTime
        let end = min(total, Double(endFrame + 1) * frameTime)
        return start...max(start + 0.1, end)
    }
}
