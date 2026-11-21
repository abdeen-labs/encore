import Accelerate
import Foundation

/// Evens out the speech level between separately generated pieces of one take.
///
/// Models set the level of each generation on their own, often by its loudest sample. A chunk with one
/// loud burst in it (a laugh, a shout) then comes out with its speech far quieter than the chunks around
/// it, and no overall gain can fix that afterwards. Leveling compares what the speech itself sits at.
public enum ChunkLeveler {
    /// Largest correction applied to any one piece, in dB.
    public static let maxGainDB = 12.0
    /// Corrections smaller than this are left alone.
    public static let deadbandDB = 1.0

    /// The level the speech in `samples` sits at, in dBFS: the median of short-window RMS levels over the
    /// parts that aren't silence. A brief burst barely moves a median. Nil when there is too little sound to judge.
    public static func speechLevel(_ samples: [Float], sampleRate: Double) -> (level: Double, activeBlocks: Int)? {
        let window = max(1, Int(0.4 * sampleRate)), hop = max(1, Int(0.1 * sampleRate))
        guard samples.count >= window else { return nil }
        var energies: [Double] = []
        samples.withUnsafeBufferPointer { p in
            var start = 0
            while start + window <= samples.count {
                var meanSquare: Float = 0
                vDSP_measqv(p.baseAddress! + start, 1, &meanSquare, vDSP_Length(window))
                energies.append(Double(meanSquare))
                start += hop
            }
        }
        // Drop silence outright, then anything well under the average of what's left (pauses, breaths, tails).
        let audible = energies.filter { $0 > 1e-6 }  // above -60 dBFS
        guard !audible.isEmpty else { return nil }
        let mean = audible.reduce(0, +) / Double(audible.count)
        let active = audible.filter { $0 >= mean * 0.1 }.sorted()
        guard active.count >= 3 else { return nil }
        return (10 * log10(active[active.count / 2]), active.count)
    }

    /// Gain in dB for each piece that brings its speech level to the group's, weighted by how much speech
    /// each piece has. Pieces that can't be judged get 0.
    public static func gains(for pieces: [[Float]], sampleRate: Double) -> [Double] {
        let levels = pieces.map { speechLevel($0, sampleRate: sampleRate) }
        let judged = levels.compactMap { $0 }
        guard judged.count >= 2 else { return [Double](repeating: 0, count: pieces.count) }
        let weight = Double(judged.reduce(0) { $0 + $1.activeBlocks })
        let target = judged.reduce(0) { $0 + $1.level * Double($1.activeBlocks) } / weight
        return levels.map { level in
            guard let level else { return 0 }
            let gain = min(maxGainDB, max(-maxGainDB, target - level.level))
            return abs(gain) < deadbandDB ? 0 : gain
        }
    }

    /// Applies `gains(for:)` to the pieces. If that pushes anything past full scale, everything is turned
    /// down together so the balance survives and nothing clips.
    public static func level(_ pieces: [[Float]], sampleRate: Double) -> [[Float]] {
        let gains = gains(for: pieces, sampleRate: sampleRate)
        guard gains.contains(where: { $0 != 0 }) else { return pieces }
        var out = zip(pieces, gains).map { piece, gain -> [Float] in
            gain == 0 ? piece : vDSP.multiply(Float(pow(10, gain / 20)), piece)
        }
        let peak = out.map { $0.isEmpty ? 0 : vDSP.maximumMagnitude($0) }.max() ?? 0
        if peak > 0.98 {
            let trim = 0.98 / peak
            out = out.map { vDSP.multiply(trim, $0) }
        }
        return out
    }
}
