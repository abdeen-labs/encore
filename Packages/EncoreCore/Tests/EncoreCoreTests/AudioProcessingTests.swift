import Foundation
import Testing
@testable import EncoreCore

@Suite("Audio editing and processing")
struct AudioProcessingTests {
    let rate = 48_000.0

    func maxStep(_ s: [Float]) -> Float {
        zip(s.dropFirst(), s).map { abs($0 - $1) }.max() ?? 0
    }

    func zeroCrossings(_ s: [Float]) -> Int {
        zip(s.dropFirst(), s).filter { ($0 >= 0) != ($1 >= 0) }.count
    }

    // MARK: Silence removal

    @Test func silenceRemovalTrimsEdgesAndShortensGaps() {
        let tone = Signal.sine(220, dbfs: -12, seconds: 1)
        let samples = Signal.silence(1) + tone + Signal.silence(2) + tone + Signal.silence(0.3) + tone + Signal.silence(1.5)
        let out = PostProcessor.removeSilence(AudioBuffer(samples: samples, sampleRate: rate),
                                              options: SilenceRemovalOptions(maxSilence: 0.6, edgePadding: 0.08))
        // 3 s of tone + 0.6 s (shortened) + 0.3 s (kept) + 2 × 0.08 s padding.
        #expect(abs(out.duration - 4.06) < 0.03, "\(out.duration)")
        // No clicks: nothing jumps more than the tone itself does between samples.
        let toneStep = maxStep(tone)
        #expect(maxStep(out.samples) <= toneStep * 1.05, "\(maxStep(out.samples)) vs \(toneStep)")
    }

    @Test func silenceRemovalWithNoiseFloor() {
        let tone = Signal.sine(300, dbfs: -10, seconds: 1)
        let hiss = { (s: Double, seed: UInt64) in Signal.noise(seconds: s, rmsDB: -62, seed: seed) }
        var samples = hiss(0.8, 1) + tone + hiss(1.5, 2) + tone + hiss(0.9, 3)
        // Tone segments carry the hiss too.
        let floor = Signal.noise(seconds: Double(samples.count) / rate, rmsDB: -62, seed: 9)
        for i in samples.indices { samples[i] += floor[i] * 0.2 }
        let out = PostProcessor.removeSilence(AudioBuffer(samples: samples, sampleRate: rate),
                                              options: SilenceRemovalOptions(maxSilence: 0.4))
        #expect(abs(out.duration - (2 + 0.4 + 0.16)) < 0.04, "\(out.duration)")
    }

    @Test func postProcessingOptionsApplyBoth() {
        var options = PostProcessingOptions()
        options.removeSilence = true
        options.maxSilenceSeconds = 0.5
        options.targetLUFS = -18
        let samples = Signal.silence(0.5) + Signal.speechLike(seconds: 3, level: 0.05) + Signal.silence(2)
            + Signal.speechLike(seconds: 3, level: 0.05)
        let out = PostProcessor.apply(options, to: AudioBuffer(samples: samples, sampleRate: rate))
        #expect(out.duration < 7.3)
        #expect(abs(Loudness.integratedLoudness(out) - -18) < 0.5)
        #expect(Loudness.truePeak(out) <= -1)
    }

    // MARK: Segmenting

    @Test func segmenterCutsInPauses() {
        // Bursts of 2–6 s separated by 0.25–0.8 s pauses, ~3 minutes in all.
        var samples: [Float] = []
        var pauses: [ClosedRange<Double>] = []
        let bursts = [4.1, 5.3, 2.2, 6.0, 3.3, 4.8, 2.9, 5.5, 3.7, 4.4, 6.0, 2.5, 3.1, 5.9, 4.2, 3.6, 5.0, 2.8, 4.9, 3.9,
                      5.2, 4.0, 3.4, 5.7, 2.6, 4.5, 3.8, 5.1, 4.3, 3.0, 4.6, 5.4]
        for (i, b) in bursts.enumerated() {
            samples += Signal.speechLike(seconds: b, f0: 120 + Double(i % 5) * 10)
            let p = 0.25 + Double(i % 4) * 0.18
            let start = Double(samples.count) / rate
            pauses.append(start...(start + p))
            samples += Signal.silence(p)
        }
        let buffer = AudioBuffer(samples: samples, sampleRate: rate)
        let segments = SpeechSegmenter.segment(buffer, options: .init(maxDuration: 15, minDuration: 4))
        #expect(segments.count >= Int(buffer.duration / 15))
        #expect(segments.first?.start == 0)
        #expect(abs((segments.last?.end ?? 0) - buffer.duration) < 1e-6)
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(a.end == b.start) }
        for s in segments { #expect(s.duration <= 15 + 0.011, "\(s)") }
        for s in segments.dropLast() {
            #expect(s.endsInPause)
            #expect(pauses.contains { $0.contains(s.end) }, "cut at \(s.end) not in a pause")
        }
    }

    @Test func segmenterFallsBackWithoutPauses() {
        let buffer = AudioBuffer(samples: Signal.sine(200, dbfs: -12, seconds: 50), sampleRate: rate)
        let segments = SpeechSegmenter.segment(buffer, options: .init(maxDuration: 20))
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.duration <= 20.01 })
    }

    @Test func stitchRestoresTiming() throws {
        let segments = [AudioSegment(index: 0, start: 0, end: 2), AudioSegment(index: 1, start: 2, end: 5)]
        let a = AudioBuffer(samples: Signal.sine(300, dbfs: -6, seconds: 1.8, rate: 24_000), sampleRate: 24_000)
        let b = AudioBuffer(samples: Signal.sine(300, dbfs: -6, seconds: 2.5, rate: 24_000), sampleRate: 24_000)
        let out = try SpeechSegmenter.stitch([(segments[0], a), (segments[1], b)], sampleRate: 24_000)
        #expect(out.samples.count == 5 * 24_000)
        // Second piece starts at 2 s; the gap before it is silent.
        #expect(out.samples[Int(1.9 * 24_000)] == 0)
        #expect(abs(out.samples[2 * 24_000 + 1_000]) > 0)
    }

    // MARK: Editing

    @Test(arguments: [(48_000.0, 16_000.0), (24_000, 48_000), (44_100, 24_000), (22_050, 16_000)])
    func resampleKeepsLengthAndPitch(from: Double, to: Double) throws {
        let input = AudioBuffer(samples: Signal.sine(440, dbfs: -6, seconds: 2, rate: from), sampleRate: from)
        let out = try AudioEdit.resample(input, to: to)
        #expect(out.samples.count == Int((2 * to).rounded()))
        #expect(out.sampleRate == to)
        // 440 Hz → 880 zero crossings per second, whatever the rate.
        let crossings = zeroCrossings(Array(out.samples[Int(0.1 * to)..<Int(1.9 * to)]))
        #expect(abs(crossings - Int(1.8 * 880)) <= 2, "\(crossings)")
        // Level preserved, no gain change.
        #expect(abs(out.peakDBFS - -6) < 0.1)
    }

    @Test func resampleDoesNotShiftTime() throws {
        var samples = [Float](repeating: 0, count: 48_000)
        samples[24_000] = 1
        let out = try AudioEdit.resample(AudioBuffer(samples: samples, sampleRate: 48_000), to: 16_000)
        let peakIndex = out.samples.indices.max { abs(out.samples[$0]) < abs(out.samples[$1]) }!
        #expect(abs(peakIndex - 8_000) <= 1, "\(peakIndex)")
    }

    @Test func crossfadeIsContinuous() throws {
        let a = AudioBuffer(samples: [Float](repeating: 0.5, count: 4_800), sampleRate: rate)
        let b = AudioBuffer(samples: [Float](repeating: -0.5, count: 4_800), sampleRate: rate)
        let hard = try AudioEdit.concatenate([a, b])
        #expect(hard.samples.count == 9_600)
        #expect(maxStep(hard.samples) == 1)
        let faded = try AudioEdit.concatenate([a, b], crossfade: 0.01, curve: .linear)
        #expect(faded.samples.count == 9_600 - 480)
        #expect(maxStep(faded.samples) <= 1.0 / 480 + 1e-4)
        // Equal power keeps a steady level for uncorrelated material and stays smooth.
        let ep = try AudioEdit.concatenate([a, b], crossfade: 0.01)
        #expect(maxStep(ep.samples) < 0.01)
    }

    @Test func concatenateResamplesMismatchedRates() throws {
        let a = AudioBuffer(samples: Signal.sine(200, dbfs: -6, seconds: 1, rate: 24_000), sampleRate: 24_000)
        let b = AudioBuffer(samples: Signal.sine(200, dbfs: -6, seconds: 1, rate: 48_000), sampleRate: 48_000)
        let out = try AudioEdit.concatenate([a, b])
        #expect(out.sampleRate == 24_000)
        #expect(out.samples.count == 48_000)
    }

    @Test func trimGainSilence() {
        let buffer = AudioBuffer(samples: Signal.sine(100, dbfs: -6, seconds: 3), sampleRate: rate)
        let cut = AudioEdit.trim(buffer, to: 1...2.5)
        #expect(cut.samples.count == 72_000)
        #expect(cut.samples[0] == buffer.samples[48_000])
        #expect(abs(AudioEdit.gain(buffer, decibels: -6).peakDBFS - -12) < 0.01)
        let padded = AudioEdit.insertSilence(buffer, at: 1, duration: 0.5)
        #expect(padded.samples.count == buffer.samples.count + 24_000)
        #expect(padded.samples[48_000..<72_000].allSatisfy { $0 == 0 })
        #expect(padded.samples[72_000] == buffer.samples[48_000])
    }

    // MARK: Peaks

    @Test func peaksFromBuffer() {
        // Ramp −1…1 over 1000 samples, 10 samples per bucket.
        let samples = (0..<1000).map { Float($0) / 499.5 - 1 }
        let peaks = WaveformPeaks(buffer: AudioBuffer(samples: samples, sampleRate: 1000), samplesPerBucket: 10)
        #expect(peaks.count == 100)
        #expect(peaks.mins[0] == samples[0])
        #expect(peaks.maxs[0] == samples[9])
        #expect(peaks.maxs[99] == samples[999])
        // Rebucketing to 4 columns: each covers 25 base buckets.
        let four = peaks.buckets(count: 4)
        #expect(four.count == 4)
        #expect(four[0].min == samples[0])
        #expect(four[0].max == samples[249])
        #expect(four[3].max == samples[999])
        // A zoomed range: 0.5…0.6 s → base buckets 50…59.
        let zoom = peaks.buckets(count: 2, in: 0.5...0.6)
        #expect(zoom[0].min == samples[500])
        #expect(zoom[1].max == samples[599])
        // RMS of a constant is the constant.
        let flat = WaveformPeaks(buffer: AudioBuffer(samples: [Float](repeating: 0.25, count: 4_800), sampleRate: rate))
        #expect(flat.buckets(count: 3).allSatisfy { abs($0.rms - 0.25) < 1e-6 })
    }

    @Test func suggestedSelectionPrefersContinuousSpeech() {
        // 0–10 s faint hiss, 10–14 speech, 14–15 pause, 15–28 speech, 28–35 hiss.
        let samples = Signal.noise(seconds: 10, rmsDB: -60) + Signal.speechLike(seconds: 4) + Signal.silence(1)
            + Signal.speechLike(seconds: 13, f0: 160) + Signal.noise(seconds: 7, rmsDB: -60, seed: 3)
        let peaks = WaveformPeaks(buffer: AudioBuffer(samples: samples, sampleRate: rate))
        let pick = peaks.suggestedSelection(length: 10)
        #expect(pick.lowerBound >= 14.3 && pick.upperBound <= 28.7, "\(pick)")
        #expect(abs((pick.upperBound - pick.lowerBound) - 10) < 1.2, "\(pick)")
        // Shorter than the target: the whole recording.
        let short = WaveformPeaks(buffer: AudioBuffer(samples: Signal.speechLike(seconds: 3), sampleRate: rate))
        #expect(short.suggestedSelection(length: 10) == 0...short.duration)
    }

    @Test func peaksRemainderBucket() {
        let peaks = WaveformPeaks(buffer: AudioBuffer(samples: [Float](repeating: 0.1, count: 1_005), sampleRate: 1000),
                                  samplesPerBucket: 10)
        #expect(peaks.count == 101)
        #expect(peaks.isComplete)
    }
}
