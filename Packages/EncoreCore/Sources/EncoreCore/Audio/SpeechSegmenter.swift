import Foundation

/// A span of the source recording, in seconds.
public struct AudioSegment: Sendable, Codable, Hashable, Identifiable {
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval
    /// True when the cut at `end` falls in a pause; false when no pause was found and the quietest point was used.
    public var endsInPause: Bool
    public var id: Int { index }
    public var duration: TimeInterval { end - start }
    public var range: ClosedRange<TimeInterval> { start...end }
    public init(index: Int, start: TimeInterval, end: TimeInterval, endsInPause: Bool = true) {
        self.index = index; self.start = start; self.end = end; self.endsInPause = endsInPause
    }
}

/// Splits long speech into model-sized pieces at natural pauses, and puts converted pieces back on the
/// original timeline.
public enum SpeechSegmenter {
    public struct Options: Sendable, Hashable, Codable {
        /// No segment is longer than this.
        public var maxDuration: TimeInterval = 20
        /// Cuts aren't placed before this much of a segment has elapsed (unless the recording ends).
        public var minDuration: TimeInterval = 4
        /// dBFS RMS level treated as silence; nil adapts to the material.
        public var thresholdDB: Double?
        public init(maxDuration: TimeInterval = 20, minDuration: TimeInterval = 4, thresholdDB: Double? = nil) {
            self.maxDuration = maxDuration; self.minDuration = minDuration; self.thresholdDB = thresholdDB
        }
    }

    /// Contiguous segments covering the whole buffer.
    public static func segment(_ buffer: AudioBuffer, options: Options = Options()) -> [AudioSegment] {
        segment(envelope: EnergyEnvelope(buffer: buffer), duration: buffer.duration, options: options)
    }

    /// Streams a file of any length to find the cuts (only a 10 ms energy envelope is kept in memory).
    /// Read each piece afterwards with `AudioReader.read(url, range: segment.range, sampleRate:)`.
    public static func segment(fileAt url: URL, options: Options = Options()) async throws -> [AudioSegment] {
        let reader = try await AudioFileReader(url: url)
        var env = EnergyEnvelope(sampleRate: reader.outputSampleRate)
        while let chunk = try reader.next() {
            try Task.checkCancellation()
            chunk.withUnsafeBufferPointer { env.add($0) }
        }
        env.flush()
        return segment(envelope: env, duration: Double(env.sampleCount) / env.sampleRate, options: options)
    }

    static func segment(envelope env: EnergyEnvelope, duration: TimeInterval, options: Options) -> [AudioSegment] {
        let frameTime = EnergyEnvelope.frameDuration
        let frames = env.levels.count
        guard duration > options.maxDuration, frames > 0, options.maxDuration > frameTime * 10 else {
            return [AudioSegment(index: 0, start: 0, end: duration)]
        }
        let threshold = env.silenceThreshold(override: options.thresholdDB)
        let runs = env.silentRuns(threshold: threshold).filter { $0.count >= 3 } // ≥ 30 ms
        // Smoothed level for the fallback "quietest point" search.
        let smooth: [Double] = env.levels.indices.map { i in
            let lo = max(0, i - 2), hi = min(frames, i + 3)
            let p = env.levels[lo..<hi].reduce(0.0) { $0 + ($1.isFinite ? pow(10, $1 / 10) : 0) }
            return p / Double(hi - lo)
        }

        let maxFrames = Int(options.maxDuration / frameTime)
        let minFrames = min(maxFrames / 2, Int(max(0, options.minDuration) / frameTime))
        var cuts: [(frame: Int, inPause: Bool)] = []
        var pos = 0
        while frames - pos > maxFrames {
            let lo = pos + max(1, minFrames), hi = pos + maxFrames
            // Best pause: long and late. Cut in its middle.
            var best: (frame: Int, score: Double)?
            for run in runs {
                let center = (run.lowerBound + run.upperBound) / 2
                guard center >= lo, center <= hi else { continue }
                let length = Double(run.count) * frameTime
                let score = min(length, 0.8) + 0.15 * Double(center - lo) / Double(max(1, hi - lo))
                if best == nil || score > best!.score { best = (center, score) }
            }
            if let best {
                cuts.append((best.frame, true))
                pos = best.frame
            } else {
                // No pause: quietest moment in the second half of the window.
                // Among near-equally quiet frames (within 1 dB) take the latest, so segments stay long.
                let from = max(lo, pos + maxFrames / 2)
                let floor = (from...hi).map { smooth[$0] }.min() ?? 0
                let quietest = (from...hi).last { smooth[$0] <= floor * 1.26 } ?? hi
                cuts.append((quietest, false))
                pos = quietest
            }
        }
        var segments: [AudioSegment] = []
        var start = 0.0
        for (i, cut) in cuts.enumerated() {
            let t = min(duration, env.time(ofFrame: cut.frame))
            segments.append(AudioSegment(index: i, start: start, end: t, endsInPause: cut.inPause))
            start = t
        }
        segments.append(AudioSegment(index: cuts.count, start: start, end: duration))
        return segments
    }

    /// Places processed pieces back at their segments' original start times. A piece that comes back longer
    /// than its slot overlaps the next (they meet in a pause, so the overlap is near-silent); shorter pieces leave
    /// silence. Edges get a short fade so nothing clicks. Pieces at other sample rates are resampled to `sampleRate`.
    public static func stitch(_ pieces: [(segment: AudioSegment, audio: AudioBuffer)], sampleRate: Double,
                              fade: TimeInterval = 0.005) throws -> AudioBuffer {
        var placed: [(offset: Int, samples: [Float])] = []
        var length = 0
        for piece in pieces {
            var audio = piece.audio
            if abs(audio.sampleRate - sampleRate) > 0.01 { audio = try AudioEdit.resample(audio, to: sampleRate) }
            let fadeLength = Int(fade * sampleRate)
            AudioEdit.applyFades(&audio.samples, fadeIn: piece.segment.start > 0 ? fadeLength : 0, fadeOut: fadeLength)
            let offset = Int((piece.segment.start * sampleRate).rounded())
            placed.append((offset, audio.samples))
            length = max(length, offset + audio.samples.count, Int((piece.segment.end * sampleRate).rounded()))
        }
        var out = [Float](repeating: 0, count: length)
        for (offset, samples) in placed {
            for (i, s) in samples.enumerated() { out[offset + i] += s }
        }
        return AudioBuffer(samples: out, sampleRate: sampleRate)
    }
}
