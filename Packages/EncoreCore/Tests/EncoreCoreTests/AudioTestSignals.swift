import Foundation
@testable import EncoreCore

/// Synthetic test signals.
enum Signal {
    /// A sine whose peak is `dbfs` relative to full scale (so −20 dBFS = amplitude 0.1).
    static func sine(_ freq: Double, dbfs: Double, seconds: Double, rate: Double = 48_000, phase: Double = 0) -> [Float] {
        let a = pow(10, dbfs / 20)
        let n = Int(seconds * rate)
        return (0..<n).map { Float(a * sin(2 * .pi * freq * Double($0) / rate + phase)) }
    }

    static func silence(_ seconds: Double, rate: Double = 48_000) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// Deterministic white noise at an RMS level (dBFS, where full-scale RMS = 1).
    static func noise(seconds: Double, rmsDB: Double, rate: Double = 48_000, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        let n = Int(seconds * rate)
        let scale = pow(10, rmsDB / 20) * 3.0.squareRoot() // uniform in ±1 has RMS 1/√3
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53) * 2 - 1
            return Float(u * scale)
        }
    }

    /// Speech-ish: amplitude-modulated harmonic tone with sharp syllable onsets (high crest factor).
    static func speechLike(seconds: Double, rate: Double = 48_000, level: Double = 0.3, f0: Double = 140) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let syllable = pow(max(0, sin(2 * .pi * 4 * t)), 3)
            var v = 0.0
            for h in 1...8 { v += sin(2 * .pi * f0 * Double(h) * t + Double(h)) / Double(h) }
            return Float(level * syllable * v / 2)
        }
    }
}
