import Accelerate
import Foundation

/// Mono 32-bit float PCM. The one audio currency inside Encore.
public struct AudioBuffer: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float] = [], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    public var isEmpty: Bool { samples.isEmpty }

    public static func silence(_ seconds: TimeInterval, sampleRate: Double) -> AudioBuffer {
        AudioBuffer(samples: [Float](repeating: 0, count: max(0, Int(seconds * sampleRate))), sampleRate: sampleRate)
    }
}

// MARK: - Time ↔ sample helpers and measurements

extension AudioBuffer {
    /// Sample index for a time, clamped to `0...samples.count`.
    public func sampleIndex(at time: TimeInterval) -> Int {
        min(samples.count, max(0, Int((time * sampleRate).rounded())))
    }

    /// Sample index range for a time range, clamped to the buffer.
    public func sampleRange(for range: ClosedRange<TimeInterval>) -> Range<Int> {
        let lower = sampleIndex(at: range.lowerBound)
        return lower..<max(lower, sampleIndex(at: range.upperBound))
    }

    /// Largest absolute sample value (sample peak, not true peak).
    public var peak: Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_maxmgv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }

    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }

    /// Sample peak in dBFS (−∞ for digital silence).
    public var peakDBFS: Double { AudioMath.decibels(Double(peak)) }
    /// RMS in dBFS where a full-scale square wave is 0 dB (a full-scale sine reads −3.01).
    public var rmsDBFS: Double { AudioMath.decibels(Double(rms)) }
}

/// Small numeric helpers shared by the audio code.
public enum AudioMath {
    public static func decibels(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }
    public static func amplitude(decibels: Double) -> Double { pow(10, decibels / 20) }

    /// Averages interleaved frames into mono, appending to `out`.
    static func mixdown(interleaved: UnsafePointer<Float>, frames: Int, channels: Int, into out: inout [Float]) {
        guard frames > 0 else { return }
        let mono = [Float](unsafeUninitializedCapacity: frames) { d, count in
            let d = d.baseAddress!
            if channels <= 1 {
                d.initialize(from: interleaved, count: frames)
            } else {
                vDSP_vadd(interleaved, vDSP_Stride(channels), interleaved + 1, vDSP_Stride(channels), d, 1, vDSP_Length(frames))
                for c in 2..<max(2, channels) {
                    vDSP_vadd(interleaved + c, vDSP_Stride(channels), d, 1, d, 1, vDSP_Length(frames))
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(d, 1, &scale, d, 1, vDSP_Length(frames))
            }
            count = frames
        }
        if out.isEmpty { out = mono } else { out += mono }
    }

    /// Averages deinterleaved channel pointers into mono, appending to `out`.
    static func mixdown(channels: [UnsafePointer<Float>], frames: Int, into out: inout [Float]) {
        guard frames > 0, let first = channels.first else { return }
        let mono = [Float](unsafeUninitializedCapacity: frames) { d, count in
            let d = d.baseAddress!
            d.initialize(from: first, count: frames)
            for c in channels.dropFirst() {
                vDSP_vadd(c, 1, d, 1, d, 1, vDSP_Length(frames))
            }
            if channels.count > 1 {
                var scale = 1 / Float(channels.count)
                vDSP_vsmul(d, 1, &scale, d, 1, vDSP_Length(frames))
            }
            count = frames
        }
        if out.isEmpty { out = mono } else { out += mono }
    }
}
