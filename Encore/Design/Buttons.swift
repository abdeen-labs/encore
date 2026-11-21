import SwiftUI

/// Encore's button family. Apply with `.buttonStyle(.primary)`, `.secondary`, `.ghost`,
/// `.destructive` or `.icon`. Sizes follow `.controlSize(.small / .regular / .large)`.
///
///     Button("Perform", systemImage: "play.fill") { … }.buttonStyle(.primary)
///     Button("Delete take", systemImage: "trash") { … }.buttonStyle(.icon)   // icon-only, label kept for VoiceOver
struct StageButtonStyle: ButtonStyle {
    enum Kind: Sendable { case primary, secondary, ghost, destructive }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StageButtonBody(kind: kind, configuration: configuration)
    }
}

private struct StageButtonBody: View {
    let kind: StageButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    private var height: CGFloat { Theme.ControlHeight.of(controlSize) }
    private var fontSize: CGFloat {
        switch controlSize {
        case .mini, .small: 11.5
        case .large, .extraLarge: 14
        default: 12.5
        }
    }
    private var hPad: CGFloat {
        switch controlSize {
        case .mini, .small: 10
        case .large, .extraLarge: 20
        default: 14
        }
    }

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .labelStyle(StageButtonLabelStyle())
            .font(.ui(fontSize, weight: kind == .ghost ? .medium : .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad)
            .frame(height: height)
            .frame(minWidth: height)
            .background { background(pressed: pressed) }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.s))
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { isHovered = $0 }
            .stageAnimation(Theme.Motion.quick, value: pressed)
            .stageAnimation(Theme.Motion.quick, value: isHovered)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .onTungsten
        case .secondary: .textPrimary
        case .ghost: isHovered ? .textPrimary : .textSecondary
        case .destructive: isHovered ? .textPrimary : .velvet
        }
    }

    @ViewBuilder private func background(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
        switch kind {
        case .primary:
            shape
                .fill(LinearGradient(colors: [Color(hex: 0xFFC669), .tungsten, .tungstenDeep],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.5).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                .brightness(pressed ? -0.08 : (isHovered ? 0.04 : 0))
                .glow(.tungsten, radius: isHovered && isEnabled ? 14 : 8, intensity: isEnabled ? (isHovered ? 0.45 : 0.25) : 0)
        case .secondary:
            shape
                .fill(Color.surfaceRaised)
                .brightness(pressed ? -0.03 : (isHovered ? 0.03 : 0))
                .overlay(shape.strokeBorder(isHovered ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
        case .ghost:
            shape.fill(Color.textPrimary.opacity(pressed ? 0.09 : (isHovered ? 0.05 : 0)))
        case .destructive:
            shape
                .fill(isHovered ? AnyShapeStyle(Color.velvet) : AnyShapeStyle(Color.velvet.opacity(0.1)))
                .overlay(shape.strokeBorder(Color.velvet.opacity(isHovered ? 0 : 0.45), lineWidth: 1))
                .brightness(pressed ? -0.08 : 0)
                .glow(.velvet, radius: 10, intensity: isHovered ? 0.35 : 0)
        }
    }
}

private struct StageButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Square, icon-only button. The button's title is kept for VoiceOver; add `.help("…")` for a tooltip.
///
///     Button("Play", systemImage: "play.fill") { … }.buttonStyle(.icon)
///     Button("Stop", systemImage: "stop.fill") { … }.buttonStyle(.icon(tone: .danger, filled: true))
struct IconButtonStyle: ButtonStyle {
    var tone: Tone = .neutral
    /// Draw a filled disc behind the icon (for transport controls like play/record).
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(style: self, configuration: configuration)
    }
}

private struct IconButtonBody: View {
    let style: IconButtonStyle
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let size = Theme.ControlHeight.of(controlSize)
        let pressed = configuration.isPressed
        let tint = style.tone == .neutral ? Color.textPrimary : style.tone.color
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(style.filled ? (style.tone == .neutral ? Color.backdrop : Color.onTungsten)
                                          : (isHovered ? tint : tint.opacity(style.tone == .neutral ? 0.7 : 0.9)))
            .frame(width: size, height: size)
            .background {
                if style.filled {
                    Circle()
                        .fill(style.tone == .neutral ? Color.textPrimary : style.tone.color)
                        .brightness(pressed ? -0.1 : (isHovered ? 0.05 : 0))
                        .glow(style.tone == .neutral ? .textPrimary : style.tone.color, radius: 10, intensity: isHovered ? 0.4 : 0.15)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .fill(Color.textPrimary.opacity(pressed ? 0.1 : (isHovered ? 0.06 : 0)))
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovered = $0 }
            .stageAnimation(Theme.Motion.quick, value: pressed)
            .stageAnimation(Theme.Motion.quick, value: isHovered)
    }
}

extension ButtonStyle where Self == StageButtonStyle {
    /// Tungsten-lit primary action. One per screen, ideally.
    static var primary: StageButtonStyle { .init(kind: .primary) }
    /// Neutral raised button.
    static var secondary: StageButtonStyle { .init(kind: .secondary) }
    /// Text-only button for tertiary actions.
    static var ghost: StageButtonStyle { .init(kind: .ghost) }
    /// Velvet outline that fills on hover. For delete / discard.
    static var destructive: StageButtonStyle { .init(kind: .destructive) }
}

extension ButtonStyle where Self == IconButtonStyle {
    /// Icon-only button (neutral, unfilled).
    static var icon: IconButtonStyle { .init() }
    /// Icon-only button with a tone, optionally on a filled disc.
    static func icon(tone: Tone = .neutral, filled: Bool = false) -> IconButtonStyle {
        .init(tone: tone, filled: filled)
    }
}
