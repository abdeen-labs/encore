import Foundation
import Testing
@testable import EncoreCore

@Suite("Audio loudness (BS.1770)")
struct AudioLoudnessTests {
    /// BS.1770: a 997 Hz sine at −20 dBFS in a single channel measures −23.0 LUFS (the −0.691 constant cancels
    /// the K-filter's gain near 1 kHz). Checked at several rates since the filters are recomputed per rate.
    @Test(arguments: [48_000.0, 44_100, 24_000, 16_000, 96_000])
    func sineReference(rate: Double) {
        let buffer = AudioBuffer(samples: Signal.sine(997, dbfs: -20, seconds: 20, rate: rate), sampleRate: rate)
        let m = Loudness.measure(buffer)
        #expect(abs(m.integrated - -23.01) < 0.05, "\(rate) Hz: \(m.integrated)")
        #expect(abs(m.samplePeak - -20) < 0.01)
        #expect(abs(m.truePeak - -20) < 0.05)
        #expect(m.loudnessRange < 0.1)
    }

    /// EBU Tech 3341 case 3 shape (mono, so levels are 3 dB lower than the stereo original): the quiet parts
    /// fall under the relative gate, so the result is the loud part's level, not the average.
    @Test func relativeGate() {
        let samples = Signal.sine(1000, dbfs: -33, seconds: 10) + Signal.sine(1000, dbfs: -20, seconds: 60)
            + Signal.sine(1000, dbfs: -33, seconds: 10)
        let m = Loudness.measure(AudioBuffer(samples: samples, sampleRate: 48_000))
        #expect(abs(m.integrated - -23.0) < 0.1, "\(m.integrated)")
    }

    /// Silence and very quiet passages fall under the −70 LUFS absolute gate.
    @Test func absoluteGate() {
        let samples = Signal.silence(20) + Signal.sine(1000, dbfs: -20, seconds: 20) + Signal.sine(1000, dbfs: -75, seconds: 20)
        let m = Loudness.measure(AudioBuffer(samples: samples, sampleRate: 48_000))
        #expect(abs(m.integrated - -23.0) < 0.1, "\(m.integrated)")
        #expect(Loudness.measure(AudioBuffer(samples: Signal.silence(5), sampleRate: 48_000)).integrated == -.infinity)
    }

    /// A sine at fs/4 sampled 45° off its crest: samples peak at −3 dB, the true peak is 0 dB.
    @Test func truePeakCatchesIntersamplePeaks() {
        let buffer = AudioBuffer(samples: Signal.sine(12_000, dbfs: 0, seconds: 1, phase: .pi / 4), sampleRate: 48_000)
        #expect(abs(buffer.peakDBFS - -3.01) < 0.02)
        let tp = Loudness.truePeak(buffer)
        #expect(abs(tp - 0) < 0.3, "\(tp)")
    }

    @Test func normalizeSineHitsTarget() {
        let buffer = AudioBuffer(samples: Signal.sine(440, dbfs: -30, seconds: 5), sampleRate: 48_000)
        let (out, report) = Loudness.normalize(buffer, targetLUFS: -16)
        #expect(abs(Loudness.integratedLoudness(out) - -16) < 0.1)
        #expect(report.limiterReductionDB == 0)
        #expect(Loudness.truePeak(out) <= -1)
    }

    /// Speech-like body plus 1 ms transients ~30 dB over the loudness: reaching −16 LUFS needs >10 dB of limiting
    /// on the transients; the target is still met and the true peak stays under −1 dBTP.
    @Test func normalizePeakyAudioNeverExceedsCeiling() {
        let buffer = AudioBuffer(samples: Self.peaky(body: 0.15, spike: 0.5), sampleRate: 48_000)
        for target in [-23.0, -18, -16] {
            let (out, report) = Loudness.normalize(buffer, targetLUFS: target, truePeakCeiling: -1)
            let tp = Loudness.truePeak(out)
            let lufs = Loudness.integratedLoudness(out)
            #expect(tp <= -1.0 + 1e-6, "target \(target): true peak \(tp)")
            #expect(abs(lufs - target) < 0.5, "target \(target): \(lufs) (limited \(report.limiterReductionDB) dB)")
            if target == -16 { #expect(report.limiterReductionDB > 10) }
        }
    }

    /// When reaching the target would mean squashing sustained material (not just brief peaks), normalisation
    /// lowers the gain instead and falls short of the target — and still never exceeds the ceiling.
    @Test func normalizeFallsShortRatherThanSquash() {
        // A quiet bed with loud 80 ms bursts four times a second: the bursts carry the loudness.
        var samples = Signal.sine(220, dbfs: -40, seconds: 8)
        let burst = Signal.sine(440, dbfs: -6, seconds: 0.08)
        for k in 0..<32 { let i = k * 12_000; for j in burst.indices { samples[i + j] += burst[j] } }
        let buffer = AudioBuffer(samples: samples, sampleRate: 48_000)
        let (out, report) = Loudness.normalize(buffer, targetLUFS: -8, truePeakCeiling: -1)
        #expect(Loudness.truePeak(out) <= -1.0 + 1e-6)
        #expect(report.outputLUFS < -8.5, "\(report)")
        #expect(report.inputLUFS + report.gainDB - report.outputLUFS <= 1.1, "\(report)")
    }

    static func peaky(body: Double, spike: Float) -> [Float] {
        var samples = Signal.speechLike(seconds: 12, level: body)
        // A few sharp 1 ms transients well above the body of the signal.
        for t in [1.3, 4.7, 9.1] {
            let i = Int(t * 48_000)
            for k in 0..<48 { samples[i + k] += spike * Float(sin(Double(k) * .pi / 48)) * (k % 4 < 2 ? 1 : -1) }
        }
        return samples
    }

    @Test func normalizeLeavesSilenceAlone() {
        let buffer = AudioBuffer(samples: Signal.silence(2), sampleRate: 48_000)
        #expect(Loudness.normalize(buffer, targetLUFS: -16).0 == buffer)
    }

    @Test func streamingMatchesOneShot() {
        let samples = Signal.speechLike(seconds: 8)
        let meter = LoudnessMeter(sampleRate: 48_000)
        var i = 0
        while i < samples.count { let n = min(1_234, samples.count - i); meter.process(Array(samples[i..<(i + n)])); i += n }
        let whole = Loudness.measure(AudioBuffer(samples: samples, sampleRate: 48_000))
        #expect(abs(meter.result.integrated - whole.integrated) < 1e-6)
        #expect(abs(meter.result.truePeak - whole.truePeak) < 1e-4)
    }
}
