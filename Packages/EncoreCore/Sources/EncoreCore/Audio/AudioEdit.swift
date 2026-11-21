import Accelerate
import Foundation

public enum CrossfadeCurve: String, Codable, Sendable, CaseIterable {
    /// Constant amplitude sum; right for correlated material (the same signal on both sides).
    case linear
    /// Constant power sum; right for unrelated material such as two different takes.
    case equalPower
}

/// Basic non-destructive edits. Every function returns a new buffer.
public enum AudioEdit {
    /// The part of `buffer` inside `range` (seconds), clamped to the buffer.
    public static func trim(_ buffer: AudioBuffer, to range: ClosedRange<TimeInterval>) -> AudioBuffer {
        AudioBuffer(samples: Array(buffer.samples[buffer.sampleRange(for: range)]), sampleRate: buffer.sampleRate)
    }

    /// High-quality sample-rate conversion (AudioToolbox mastering-grade SRC). The output has exactly
    /// `round(count × newRate / oldRate)` samples and no added latency.
    public static func resample(_ buffer: AudioBuffer, to rate: Double) throws -> AudioBuffer {
        guard rate > 0 else { throw AudioError.invalidArgument("Sample rate must be positive.") }
        guard abs(rate - buffer.sampleRate) > 0.01, !buffer.isEmpty else {
            return AudioBuffer(samples: buffer.samples, sampleRate: rate)
        }
        let source = try ResamplingSource(MemorySource(buffer), to: rate, chunkFrames: 65_536, mastering: true)
        var out: [Float] = []
        let expected = Int((Double(buffer.samples.count) * rate / buffer.sampleRate).rounded())
        out.reserveCapacity(expected + 1024)
        while let chunk = try source.next() { out += chunk }
        if out.count > expected { out.removeLast(out.count - expected) }
        if out.count < expected { out += repeatElement(0, count: expected - out.count) }
        return AudioBuffer(samples: out, sampleRate: rate)
    }

    /// Joins buffers end to end. With a crossfade, each join overlaps the neighbours by that long
    /// (shortened if a piece is too short). Buffers at other rates are resampled to the first one's rate.
    public static func concatenate(_ buffers: [AudioBuffer], crossfade: TimeInterval = 0,
                                   curve: CrossfadeCurve = .equalPower) throws -> AudioBuffer {
        guard let first = buffers.first else { return AudioBuffer(sampleRate: 24_000) }
        let rate = first.sampleRate
        var out = first.samples
        out.reserveCapacity(buffers.reduce(0) { $0 + $1.samples.count })
        for next in buffers.dropFirst() {
            let piece = abs(next.sampleRate - rate) > 0.01 ? try resample(next, to: rate).samples : next.samples
            let fade = min(Int(crossfade * rate), out.count, piece.count)
            if fade > 1 {
                let start = out.count - fade
                let (fadeOut, fadeIn) = crossfadeGains(count: fade, curve: curve)
                for i in 0..<fade {
                    out[start + i] = out[start + i] * fadeOut[i] + piece[i] * fadeIn[i]
                }
                out += piece[fade...]
            } else {
                out += piece
            }
        }
        return AudioBuffer(samples: out, sampleRate: rate)
    }

    /// Inserts `duration` seconds of digital silence at `time`.
    public static func insertSilence(_ buffer: AudioBuffer, at time: TimeInterval, duration: TimeInterval) -> AudioBuffer {
        var samples = buffer.samples
        samples.insert(contentsOf: repeatElement(0, count: max(0, Int((duration * buffer.sampleRate).rounded()))),
                       at: buffer.sampleIndex(at: time))
        return AudioBuffer(samples: samples, sampleRate: buffer.sampleRate)
    }

    /// Silence appended (or prepended) to a buffer.
    public static func pad(_ buffer: AudioBuffer, leading: TimeInterval = 0, trailing: TimeInterval = 0) -> AudioBuffer {
        let lead = max(0, Int((leading * buffer.sampleRate).rounded()))
        let trail = max(0, Int((trailing * buffer.sampleRate).rounded()))
        return AudioBuffer(samples: [Float](repeating: 0, count: lead) + buffer.samples + [Float](repeating: 0, count: trail),
                           sampleRate: buffer.sampleRate)
    }

    /// Multiplies by a gain in decibels.
    public static func gain(_ buffer: AudioBuffer, decibels: Double) -> AudioBuffer {
        scaled(buffer, by: Float(AudioMath.amplitude(decibels: decibels)))
    }

    public static func scaled(_ buffer: AudioBuffer, by factor: Float) -> AudioBuffer {
        var out = buffer.samples
        var f = factor
        vDSP_vsmul(buffer.samples, 1, &f, &out, 1, vDSP_Length(out.count))
        return AudioBuffer(samples: out, sampleRate: buffer.sampleRate)
    }

    /// Short fades at the edges (raised-cosine), e.g. after cutting at arbitrary points.
    public static func fade(_ buffer: AudioBuffer, in fadeIn: TimeInterval = 0, out fadeOut: TimeInterval = 0) -> AudioBuffer {
        var samples = buffer.samples
        applyFades(&samples, fadeIn: Int(fadeIn * buffer.sampleRate), fadeOut: Int(fadeOut * buffer.sampleRate))
        return AudioBuffer(samples: samples, sampleRate: buffer.sampleRate)
    }

    // MARK: Internals

    static func applyFades(_ samples: inout [Float], fadeIn: Int, fadeOut: Int) {
        let n = samples.count
        let fi = min(fadeIn, n), fo = min(fadeOut, n)
        if fi > 1 {
            for i in 0..<fi { samples[i] *= raisedCosine(Float(i) / Float(fi)) }
        }
        if fo > 1 {
            for i in 0..<fo { samples[n - 1 - i] *= raisedCosine(Float(i) / Float(fo)) }
        }
    }

    /// 0 → 0, 1 → 1, smooth at both ends.
    @inline(__always) static func raisedCosine(_ x: Float) -> Float { 0.5 - 0.5 * cos(.pi * x) }

    static func crossfadeGains(count: Int, curve: CrossfadeCurve) -> (out: [Float], in: [Float]) {
        var fadeOut = [Float](repeating: 0, count: count), fadeIn = fadeOut
        for i in 0..<count {
            let x = (Float(i) + 0.5) / Float(count)
            switch curve {
            case .linear:
                fadeIn[i] = x; fadeOut[i] = 1 - x
            case .equalPower:
                fadeIn[i] = sin(x * .pi / 2); fadeOut[i] = cos(x * .pi / 2)
            }
        }
        return (fadeOut, fadeIn)
    }
}

/// An in-memory buffer as a chunk source (lets buffers share the streaming resampler).
final class MemorySource: ChunkSource {
    let buffer: AudioBuffer
    var sampleRate: Double { buffer.sampleRate }
    private var position = 0
    private var end: Int
    init(_ buffer: AudioBuffer) { self.buffer = buffer; end = buffer.samples.count }
    func seek(to range: ClosedRange<TimeInterval>) throws {
        position = buffer.sampleIndex(at: range.lowerBound)
        end = buffer.sampleIndex(at: range.upperBound)
    }
    func next() throws -> [Float]? {
        guard position < end else { return nil }
        let n = min(65_536, end - position)
        defer { position += n }
        return Array(buffer.samples[position..<(position + n)])
    }
}
