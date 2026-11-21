import EncoreCore
import SwiftUI

/// Draws `WaveformPeaks` as mirrored bars for any visible time range: a dim peak envelope with a brighter
/// RMS core, lit up to `played` (players) or inside `highlight` (the trimmer's selection).
/// Re-buckets on every size or range change, which is cheap, so it scales from a 3 s take to a 3 h file.
struct PeaksWaveform: View {
    var peaks: WaveformPeaks?
    /// Visible span in seconds; nil shows the whole duration.
    var range: ClosedRange<TimeInterval>?
    /// Bars before this time are lit.
    var played: TimeInterval?
    /// Bars inside this range are lit (and others dimmed).
    var highlight: ClosedRange<TimeInterval>?
    var tint: Color = .tungsten
    var gain: Float = 1
    var barWidth: CGFloat = 2
    var gap: CGFloat = 1.5
    /// Total duration when peaks are still loading (so partial peaks fill from the left).
    var duration: TimeInterval?

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let step = barWidth + gap
            let count = max(1, Int((size.width + gap) / step))
            let mid = size.height / 2
            let usable = size.height
            guard let peaks, peaks.count > 0 else {
                // Waiting for peaks: a quiet dotted center line.
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: mid - 0.5, width: barWidth, height: 1)), with: .color(Color.textTertiary.opacity(0.35)))
                    x += step * 2
                }
                return
            }
            let total = duration ?? peaks.duration
            let r = range ?? 0...max(total, 0.001)
            let span = max(r.upperBound - r.lowerBound, 0.0001)
            let buckets = peaks.buckets(count: count, in: r)
            let dimPeak = Color.textTertiary.opacity(0.35)
            let dimCore = Color.textTertiary.opacity(0.85)
            let litPeak = tint.opacity(0.42)
            let litCore = tint
            for (i, b) in buckets.enumerated() {
                let x = CGFloat(i) * step
                let t = r.lowerBound + (Double(i) + 0.5) / Double(count) * span
                if t > total { break }
                let lit: Bool
                if let highlight { lit = highlight.contains(t) } else if let played { lit = t <= played } else { lit = false }
                let peakAmp = min(1, max(abs(b.min), abs(b.max)) * gain)
                let coreAmp = min(peakAmp, b.rms * gain * 1.25)
                let ph = max(1.5, CGFloat(peakAmp) * usable)
                let ch = max(1.5, CGFloat(coreAmp) * usable)
                let radius = barWidth / 2
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - ph / 2, width: barWidth, height: ph), cornerRadius: radius),
                         with: .color(lit ? litPeak : dimPeak))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - ch / 2, width: barWidth, height: ch), cornerRadius: radius),
                         with: .color(lit ? litCore : dimCore))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A glowing vertical playhead line.
struct Playhead: View {
    var color: Color = .textPrimary
    var body: some View {
        Rectangle().fill(color).frame(width: 1.5)
            .glow(.tungsten, radius: 4, intensity: 0.6)
            .allowsHitTesting(false)
    }
}
