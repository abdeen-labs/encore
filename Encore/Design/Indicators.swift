import SwiftUI

// MARK: - Chip

/// A small tag. Static, selectable (bind `isSelected`) or removable (pass `onRemove`).
///
///     Chip("English")
///     Chip("Warm", isSelected: $warm)
///     Chip("narration", symbol: "tag", onRemove: { tags.remove("narration") })
struct Chip: View {
    let title: String
    var symbol: String?
    var tone: Tone = .neutral
    var isSelected: Binding<Bool>?
    var onRemove: (() -> Void)?
    @State private var isHovered = false

    init(_ title: String, symbol: String? = nil, tone: Tone = .neutral,
         isSelected: Binding<Bool>? = nil, onRemove: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.tone = tone
        self.isSelected = isSelected
        self.onRemove = onRemove
    }

    private var selected: Bool { isSelected?.wrappedValue ?? false }

    private var tint: Color {
        if selected { return .tungsten }
        return tone == .neutral ? .textSecondary : tone.color
    }

    var body: some View {
        let content = HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(title).font(.ui(11.5, weight: .medium)).lineLimit(1)
            if let onRemove {
                Button("Remove \(title)", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovered ? Color.textPrimary : .textTertiary)
                    .padding(.leading, 1)
            }
        }
        .foregroundStyle(selected ? Color.tungsten : (tone == .neutral ? Color.textPrimary.opacity(0.85) : tone.color))
        .padding(.leading, 9)
        .padding(.trailing, onRemove == nil ? 9 : 7)
        .frame(height: 22)
        .background {
            Capsule()
                .fill(selected ? Color.tungsten.opacity(0.14) : (tone == .neutral ? Color.surfaceRaised : tone.color.opacity(0.1)))
                .overlay(Capsule().strokeBorder(selected ? Color.tungsten.opacity(0.55) : (isHovered && isSelected != nil ? .hairlineStrong : tint.opacity(tone == .neutral ? 0.12 : 0.3)), lineWidth: 1))
        }
        .onHover { isHovered = $0 }
        .stageAnimation(Theme.Motion.quick, value: selected)

        if let isSelected {
            Button { isSelected.wrappedValue.toggle() } label: { content.contentShape(Capsule()) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            content
        }
    }
}

// MARK: - Status badge

/// A tiny status lamp with an uppercase label. `pulsing` breathes the lamp (e.g. while
/// recording or loading); it holds still under Reduce Motion.
///
///     StatusBadge("Ready", tone: .success)
///     StatusBadge("Rec", tone: .danger, pulsing: true)
struct StatusBadge: View {
    let title: String
    var tone: Tone = .neutral
    var pulsing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotting) private var isSnapshotting
    @State private var phase = false

    init(_ title: String, tone: Tone = .neutral, pulsing: Bool = false) {
        self.title = title
        self.tone = tone
        self.pulsing = pulsing
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .glow(tone.color, radius: 5, intensity: tone == .neutral ? 0 : (phase ? 0.9 : 0.5))
                .opacity(pulsing && phase ? 0.55 : 1)
            Text(title)
                .font(.ui(9.5, weight: .bold))
                .tracking(1.3)
                .textCase(.uppercase)
                .foregroundStyle(tone == .neutral ? Color.textSecondary : tone.color)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tone.color.opacity(0.09)))
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.22), lineWidth: 1))
        .onAppear {
            guard pulsing, !reduceMotion, !isSnapshotting else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress bar

/// A thin linear progress bar. Pass `nil` for an indeterminate sweep.
///
///     ProgressBar(value: download.fraction)
///     ProgressBar(value: nil, tone: .success)
struct ProgressBar: View {
    var value: Double?
    var tone: Tone = .accent
    var height: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotting) private var isSnapshotting

    init(value: Double?, tone: Tone = .accent, height: CGFloat = 4) {
        self.value = value
        self.tone = tone
        self.height = height
    }

    var body: some View {
        let color = tone == .neutral ? Color.textSecondary : tone.color
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.surfaceSunken)
                    .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
                if let value {
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                        .glow(color, radius: 5, intensity: 0.35)
                        .stageAnimation(Theme.Motion.standard, value: value)
                } else if reduceMotion || isSnapshotting {
                    Capsule().fill(color.opacity(0.45))
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
                        let w = geo.size.width * 0.32
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: w)
                            .offset(x: -w + (geo.size.width + w) * phase)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

// MARK: - Activity indicator

/// An indeterminate "working" indicator drawn as a small bouncing level meter.
///
///     ActivityIndicator()
///     ActivityIndicator(tone: .danger, size: 22)
struct ActivityIndicator: View {
    var tone: Tone = .accent
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotting) private var isSnapshotting

    init(tone: Tone = .accent, size: CGFloat = 16) {
        self.tone = tone
        self.size = size
    }

    var body: some View {
        let still = reduceMotion || isSnapshotting
        TimelineView(.animation(paused: still)) { context in
            let t = still ? 0.35 : context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: size * 0.12) {
                ForEach(0..<4, id: \.self) { i in
                    let h = 0.3 + 0.7 * abs(sin(t * 4.2 + Double(i) * 0.9))
                    Capsule()
                        .fill(tone.color)
                        .frame(width: size * 0.14, height: size * h)
                }
            }
            .frame(width: size, height: size)
            .glow(tone.color, radius: 4, intensity: 0.4)
        }
        .accessibilityElement()
        .accessibilityLabel("Working")
    }
}

// MARK: - Waveform

/// A mirrored bar waveform. The played portion is lit tungsten. Pass `onSeek` to make it
/// scrubbable.
///
///     Waveform(samples: take.peaks, progress: player.progress)
///     Waveform(samples: Waveform.placeholder(count: 120), progress: 0.4) { player.seek(to: $0) }
struct Waveform: View {
    /// Peak amplitudes in 0…1.
    var samples: [Float]
    /// Played fraction in 0…1.
    var progress: Double = 0
    var playedColor: Color = .tungsten
    var onSeek: ((Double) -> Void)?

    init(samples: [Float], progress: Double = 0, playedColor: Color = .tungsten, onSeek: ((Double) -> Void)? = nil) {
        self.samples = samples
        self.progress = progress
        self.playedColor = playedColor
        self.onSeek = onSeek
    }

    var body: some View {
        Canvas { ctx, size in
            guard !samples.isEmpty else { return }
            let gap: CGFloat = 1.5
            let barWidth = max(1, (size.width - gap * CGFloat(samples.count - 1)) / CGFloat(samples.count))
            let mid = size.height / 2
            let playedX = size.width * progress
            for (i, s) in samples.enumerated() {
                let x = CGFloat(i) * (barWidth + gap)
                let h = max(1.5, CGFloat(min(max(s, 0), 1)) * size.height)
                let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                let color: Color = x + barWidth / 2 <= playedX ? playedColor : Color.textTertiary.opacity(0.7)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
        .overlay(alignment: .leading) {
            GeometryReader { geo in
                if progress > 0 && progress < 1 {
                    Rectangle().fill(Color.textPrimary).frame(width: 1.5)
                        .glow(.tungsten, radius: 4, intensity: 0.6)
                        .offset(x: geo.size.width * progress)
                }
            }
        }
        .overlay {
            if let onSeek {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            onSeek(min(max(g.location.x / max(geo.size.width, 1), 0), 1))
                        })
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Int(progress * 100)) percent played")
    }

    /// Deterministic pseudo-speech peaks for placeholders and previews.
    static func placeholder(count: Int, seed: Int = 7) -> [Float] {
        (0..<count).map { i in
            let x = Double(i + seed * 13)
            let envelope = 0.55 + 0.45 * sin(x * 0.11) * sin(x * 0.037 + 1)
            let jitter = abs(sin(x * 1.7) * cos(x * 0.53))
            return Float(max(0.06, min(1, envelope * (0.35 + 0.65 * jitter))))
        }
    }
}
