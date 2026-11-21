#if DEBUG
import EncoreCore
import SwiftUI

/// Deterministic fake peaks that look like speech: phrases of syllables separated by pauses.
/// Built directly as buckets, so even a multi-hour "recording" is instant.
enum AudioFixtures {
    static func speechPeaks(duration: TimeInterval, bucketsPerSecond: Double = 100, seed: UInt64 = 7,
                            loudness: Float = 0.55) -> WaveformPeaks {
        let n = Int(duration * bucketsPerSecond)
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func rand() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 10_000) / 10_000
        }
        var mins = [Float](repeating: 0, count: n), maxs = mins, rms = mins
        var i = 0
        var phraseEnd = Double(0)
        var phraseLevel = 0.8
        while i < n {
            let t = Double(i) / bucketsPerSecond
            if t >= phraseEnd {
                // A pause, then a new phrase at its own level.
                let pause = Int((0.2 + rand() * 0.9) * bucketsPerSecond)
                for k in i..<min(n, i + pause) {
                    let a = 0.004 + 0.004 * rand()
                    maxs[k] = Float(a); mins[k] = -Float(a); rms[k] = Float(a * 0.5)
                }
                i += pause
                phraseEnd = Double(i) / bucketsPerSecond + 1.2 + rand() * 4.5
                phraseLevel = 0.45 + rand() * 0.55
                continue
            }
            // One syllable: a rise and fall of random length and strength, sometimes with a short gap after.
            let length = max(2, Int((0.09 + rand() * 0.24) * bucketsPerSecond))
            let strength = phraseLevel * (0.2 + 0.8 * pow(rand(), 0.7)) * Double(loudness) / 0.55
            for k in 0..<length where i + k < n {
                let x = Double(k) / Double(length)
                let env = pow(sin(.pi * x), 1.4)
                let a = 0.006 + strength * env * (0.75 + 0.25 * rand())
                maxs[i + k] = Float(min(0.98, a))
                mins[i + k] = -Float(min(0.98, a * (0.8 + 0.2 * rand())))
                rms[i + k] = Float(a * (0.28 + 0.12 * rand()))
            }
            i += length
            if rand() < 0.25 {
                let gap = Int(rand() * 0.07 * bucketsPerSecond)
                for k in i..<min(n, i + gap) { maxs[k] = 0.01; mins[k] = -0.01; rms[k] = 0.004 }
                i += gap
            }
        }
        return WaveformPeaks(sampleRate: 48_000, samplesPerBucket: Int(48_000 / bucketsPerSecond),
                             mins: mins, maxs: maxs, rms: rms, duration: duration)
    }
}

/// The audio components in their states, for the component gallery.
struct AudioGallerySection: View {
    private static let take = AudioFixtures.speechPeaks(duration: 42.2, seed: 3)
    private static let line1 = AudioFixtures.speechPeaks(duration: 6.4, seed: 11)
    private static let line2 = AudioFixtures.speechPeaks(duration: 9.1, seed: 12)
    private static let line3 = AudioFixtures.speechPeaks(duration: 3.7, seed: 13)
    private static let longFile = AudioFixtures.speechPeaks(duration: 4_334, bucketsPerSecond: 50, seed: 5)
    private static let interview = AudioFixtures.speechPeaks(duration: 48, seed: 9)

    @State private var longSelection: ClosedRange<TimeInterval> = 1_812.4...1_822.0
    @State private var tooLong: ClosedRange<TimeInterval> = 3.0...29.5
    @State private var tooShort: ClosedRange<TimeInterval> = 11.2...14.0

    /// Set `ENCORE_GALLERY_AUDIO=/path/to/file` to also render a real file through the streaming path.
    private static let realFile: URL? = ProcessInfo.processInfo.environment["ENCORE_GALLERY_AUDIO"]
        .map { URL(fileURLWithPath: $0) }
        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    @State private var realSelection: ClosedRange<TimeInterval> = 0...10

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let url = Self.realFile {
                WaveformPlayer(url: url, title: url.lastPathComponent, subtitle: "Real file (ENCORE_GALLERY_AUDIO)")
                WaveformPlayer(url: url, title: url.lastPathComponent, style: .compact)
                WaveformTrimmer(url: url, selection: $realSelection)
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                WaveformPlayer(previewPeaks: Self.take, title: "Take 03 — The house lights dim",
                               subtitle: "Captain · Qwen3-TTS 1.7B · 24 kHz", time: 14.2)
                WaveformPlayer(previewPeaks: Self.interview, title: "Interview excerpt.m4a",
                               subtitle: "Changed to Narrator — Warm")
            }
            VStack(spacing: Theme.Space.s) {
                WaveformPlayer(previewPeaks: Self.line1, title: "Line 1", style: .compact, time: 2.8)
                WaveformPlayer(previewPeaks: Self.line2, title: "Line 2", style: .compact)
                WaveformPlayer(previewPeaks: Self.line3, title: "Line 3", style: .compact)
            }
            WaveformTrimmer(previewPeaks: Self.longFile, selection: $longSelection,
                            title: "Board meeting recording — full.m4a", visible: 1_796...1_838)
            HStack(alignment: .top, spacing: Theme.Space.l) {
                WaveformTrimmer(previewPeaks: Self.interview, selection: $tooLong, title: "Interview excerpt.m4a")
                WaveformTrimmer(previewPeaks: Self.interview, selection: $tooShort, title: "Interview excerpt.m4a")
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                RecordingPanel(state: RecordingDisplay(permission: .undetermined), onRecord: {}, onStop: {})
                RecordingPanel(state: RecordingDisplay(permission: .granted, isRecording: true, elapsed: 8.4, level: -21,
                                                       levels: Self.liveLevels), onRecord: {}, onStop: {})
            }
            RecordingPanel(state: RecordingDisplay(permission: .denied), onRecord: {}, onStop: {})
            VStack(spacing: 0) {
                PlayerDockBar(title: "Take 03 — The house lights dim", subtitle: "Captain · Qwen3-TTS 1.7B",
                              peaks: Self.take, gain: WaveformLoader.gain(for: Self.take),
                              currentTime: 14.2, duration: 42.2, isPlaying: true)
                Rectangle().fill(Color.hairline).frame(height: 1)
                PlayerDockBar.idle
            }
            .surface(.sunken)
        }
    }

    private static let liveLevels: [Float] = (0..<170).map { i in
        let x = Double(i)
        let phrase = (i % 45) < 38 ? 1.0 : 0.08
        return Float(min(1, max(0.04, phrase * (0.45 + 0.4 * abs(sin(x * 0.55)) * abs(cos(x * 0.13))))))
    }
}
#endif
