import AppKit
import SwiftUI

// MARK: - Surface

/// Elevation of a surface on the stage.
enum SurfaceLevel: Sendable {
    /// Input wells and tracks, cut into the surface.
    case sunken
    /// Cards and panels (default).
    case card
    /// Things on top of cards: popovers, toasts, the sheet body.
    case raised

    var fill: Color {
        switch self {
        case .sunken: .surfaceSunken
        case .card: .surface
        case .raised: .surfaceRaised
        }
    }
}

extension View {
    /// Paints a themed surface behind the view: fill, hairline border, a faint top sheen.
    ///
    ///     VStack { … }.padding(16).surface()
    ///     HStack { … }.surface(.sunken, radius: Theme.Radius.s)
    func surface(_ level: SurfaceLevel = .card, radius: CGFloat = Theme.Radius.l) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(level.fill)
                .overlay {
                    if level != .sunken {
                        // Light falls from above: the top edge catches it.
                        shape.fill(LinearGradient(colors: [.white.opacity(0.025), .clear],
                                                  startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
                    } else {
                        shape.strokeBorder(.black.opacity(0.5), lineWidth: 1).blur(radius: 1.5).clipShape(shape)
                    }
                }
                .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
        }
    }
}

/// A padded card surface.
///
///     Card { Text("Take 3") }
///     Card(padding: 0) { list rows… }
struct Card<Content: View>: View {
    var level: SurfaceLevel = .card
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content

    init(_ level: SurfaceLevel = .card, padding: CGFloat = Theme.Space.l, @ViewBuilder content: () -> Content) {
        self.level = level
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(level)
    }
}

// MARK: - Section header

/// A heading for a group of content: display-serif title, optional caption, trailing slot.
///
///     SectionHeader("Voice", subtitle: "Who performs the line")
///     SectionHeader("Takes") { Button("Clear", action: clear).buttonStyle(.ghost) }
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textRole(.heading)
                if let subtitle { Text(subtitle).textRole(.caption) }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Perforated divider

/// A ticket-stub tear line: a dotted rule with half-moon notches cut into both ends.
/// Inside a `Card`, pass the card's horizontal padding as `bleed` so the notches bite the edges.
///
///     PerforatedDivider()
///     PerforatedDivider(bleed: 16)
struct PerforatedDivider: View {
    var bleed: CGFloat = 0
    /// Color that fills the notches; match the ground the card sits on.
    var notchFill: Color = .stage

    private let radius: CGFloat = 9

    var body: some View {
        ZStack {
            HLine()
                .stroke(Color.hairlineStrong, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 6]))
                .frame(height: 1.5)
                .padding(.horizontal, bleed > 0 ? radius + 6 : 0)
            if bleed > 0 {
                HStack {
                    Notch(opensTo: .trailing).fill(notchFill)
                        .overlay(Notch(opensTo: .trailing, open: true).stroke(Color.hairline, lineWidth: 1))
                        .frame(width: radius, height: radius * 2)
                    Spacer()
                    Notch(opensTo: .leading).fill(notchFill)
                        .overlay(Notch(opensTo: .leading, open: true).stroke(Color.hairline, lineWidth: 1))
                        .frame(width: radius, height: radius * 2)
                }
            }
        }
        .frame(height: radius * 2)
        .padding(.horizontal, -bleed)
        .accessibilityHidden(true)
    }

    /// A half-disc whose flat side sits on the card edge.
    private struct Notch: Shape {
        var opensTo: HorizontalEdge
        var open = false
        func path(in rect: CGRect) -> Path {
            let left = opensTo == .trailing
            let center = CGPoint(x: left ? rect.minX : rect.maxX, y: rect.midY)
            var p = Path()
            p.addArc(center: center, radius: rect.height / 2,
                     startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: !left)
            if !open { p.closeSubpath() }
            return p
        }
    }
}

/// A horizontal line through the middle of its frame (for dashed rules and leaders).
struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

// MARK: - Key-value row

/// A label on the left, a monospaced value on the right, joined by a dotted leader.
/// When space runs short the leader shrinks first, then the value wraps (right-aligned); neither side truncates.
///
///     KeyValueRow("Sample rate", value: "24 kHz")
///     KeyValueRow("Model") { StatusBadge("Loaded", tone: .success) }
struct KeyValueRow<Value: View>: View {
    let key: String
    @ViewBuilder var value: Value

    init(_ key: String, @ViewBuilder value: () -> Value) {
        self.key = key
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(key).textRole(.body, color: .textSecondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
            HLine()
                .stroke(Color.hairlineStrong, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 4]))
                .frame(minWidth: 4, maxWidth: .infinity)
                .frame(height: 1.2)
            value
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

extension KeyValueRow where Value == AnyView {
    init(_ key: String, value: String) {
        self.init(key) { AnyView(Text(value).textRole(.mono).textSelection(.enabled)) }
    }
}

// MARK: - Advanced disclosure

/// A collapsible group for secondary settings, closed by default.
///
///     AdvancedDisclosure { StageSlider("Temperature", value: $t, in: 0...2) }
///     AdvancedDisclosure("Sampling", isExpanded: $open) { … }
struct AdvancedDisclosure<Content: View>: View {
    let title: String
    private let external: Binding<Bool>?
    @ViewBuilder var content: Content
    @State private var internalExpanded = false
    @State private var isHovered = false

    /// Caller-owned expansion state.
    init(_ title: String = "Advanced", isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.external = isExpanded
        self.content = content()
    }

    /// Self-managed expansion state (starts collapsed).
    init(_ title: String = "Advanced", @ViewBuilder content: () -> Content) {
        self.title = title
        self.external = nil
        self.content = content()
    }

    private var isExpanded: Bool { external?.wrappedValue ?? internalExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withStageAnimation(Theme.Motion.standard) {
                    if let external { external.wrappedValue.toggle() } else { internalExpanded.toggle() }
                }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(isExpanded ? Color.tungsten : .textTertiary)
                    Text(title).textRole(.eyebrow, color: isHovered || isExpanded ? .textSecondary : .textTertiary)
                    Rectangle().fill(Color.hairline).frame(height: 1)
                }
                .contentShape(Rectangle())
                .padding(.vertical, Theme.Space.s)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.m) { content }
                    .padding(.top, Theme.Space.s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

// MARK: - Stage backdrop

/// The window ground: warm ink, a soft overhead wash of light and a vignette, with a faint
/// film grain. Cheap: two gradients and one tiled 128px noise image.
struct StageBackdrop: View {
    var body: some View {
        ZStack {
            Color.backdrop
            RadialGradient(colors: [Color(hex: 0x2A2017, opacity: 0.55), .clear],
                           center: .init(x: 0.55, y: -0.15), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [.clear, .black.opacity(0.45)],
                           center: .center, startRadius: 380, endRadius: 1200)
            Image(nsImage: Grain.image)
                .resizable(resizingMode: .tile)
                .opacity(0.035)
                .blendMode(.screen)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

enum Grain {
    /// A 128×128 monochrome noise tile, generated once.
    static let image: NSImage = {
        let side = 128
        var generator = SplitMix(seed: 0xE1C0_4E)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: side, bitsPerPixel: 8)!
        let data = rep.bitmapData!
        for i in 0..<(side * side) { data[i] = UInt8(truncatingIfNeeded: generator.next() >> 56) }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
