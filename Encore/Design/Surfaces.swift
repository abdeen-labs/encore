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
    /// Paints a themed surface behind the view: fill and hairline border. Cards and raised surfaces float on a
    /// soft cocoa shadow; sunken wells get a faint inner shade along the top edge.
    ///
    ///     VStack { … }.padding(16).surface()
    ///     HStack { … }.surface(.sunken, radius: Theme.Radius.s)
    func surface(_ level: SurfaceLevel = .card, radius: CGFloat = Theme.Radius.l) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            if level == .sunken {
                shape
                    .fill(level.fill)
                    .overlay {
                        // Pressed into the cream: a little shade under the top edge.
                        shape.fill(LinearGradient(colors: [Color.shadow.opacity(0.06), .clear],
                                                  startPoint: .top, endPoint: .init(x: 0.5, y: 0.12)))
                    }
                    .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
            } else {
                shape
                    .fill(level.fill)
                    .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
                    .lift()
            }
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

/// A heading for a group of content: a sans `section` title, optional caption, trailing slot.
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
                Text(title).textRole(.section)
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

// MARK: - Hairline

/// A 1pt rule in `Color.hairline`: the plain way to separate things. Horizontal by default.
///
///     Hairline()
///     Hairline(.vertical).frame(height: 18)
struct Hairline: View {
    var axis: Axis = .horizontal

    init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}

// MARK: - Squiggle divider

/// A hand-drawn wavy rule, the one playful line in the app.
///
/// Only for the line above the action row of a sheet (`SheetContainer` draws it there). Everywhere else,
/// separate things with `Hairline()` or space.
///
///     SquiggleDivider()
struct SquiggleDivider: View {
    var color: Color = .hairlineStrong

    var body: some View {
        Squiggle(wavelength: 14, amplitude: 2.2)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .frame(height: 8)
            .accessibilityHidden(true)
    }

    private struct Squiggle: Shape {
        var wavelength: CGFloat
        var amplitude: CGFloat
        func path(in rect: CGRect) -> Path {
            Path { p in
                let mid = rect.midY
                p.move(to: CGPoint(x: rect.minX, y: mid))
                var x = rect.minX
                var up = true
                while x < rect.maxX {
                    let next = min(x + wavelength / 2, rect.maxX)
                    p.addQuadCurve(to: CGPoint(x: next, y: mid),
                                   control: CGPoint(x: (x + next) / 2, y: mid + (up ? -amplitude * 2 : amplitude * 2)))
                    up.toggle()
                    x = next
                }
            }
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

/// A key on the left in secondary text, its value right-aligned on the right.
/// When space runs short the value wraps (right-aligned); neither side truncates.
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
            Spacer(minLength: Theme.Space.m)
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
                        .foregroundStyle(isExpanded ? Color.textSecondary : .textTertiary)
                    Text(title).textRole(.eyebrow, color: isHovered || isExpanded ? .textSecondary : .textTertiary)
                    Hairline()
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

/// The window ground: cream with a faint paper grain, nothing else (the stage panel's blush is the one
/// ambient color). Cheap: one tiled 128px noise image.
struct StageBackdrop: View {
    var body: some View {
        ZStack {
            Color.backdrop
            Image(nsImage: Grain.image)
                .resizable(resizingMode: .tile)
                .opacity(0.03)
                .blendMode(.multiply)
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
