import SwiftUI

/// Encore's button family. Apply with `.buttonStyle(.primary)`, `.secondary`, `.ghost`,
/// `.destructive`, `.icon` or `.play(isPlaying:)`. Sizes follow `.controlSize(.small / .regular / .large)`.
/// Only `.primary` (the next step) and `.play` while playing are tangerine.
///
/// Buttons are capsules. The solid ones sit on a lip, a darker edge underneath that squashes when pressed,
/// so a click feels like pressing a soft key.
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

/// How far the lip shows below a solid button at rest, and how far the face travels when pressed.
private enum Lip {
    static func height(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini, .small: 2
        case .large, .extraLarge: 3.5
        default: 3
        }
    }
    static let travel: CGFloat = 0.7
}

private struct StageButtonBody: View {
    let kind: StageButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    private var height: CGFloat { Theme.ControlHeight.of(controlSize) }
    /// The label's role font: `label` (12) small, `headline` (13) regular, `section` (15) large.
    private var labelFont: Font {
        switch controlSize {
        case .mini, .small: TextRole.label.font
        case .large, .extraLarge: TextRole.section.font
        default: TextRole.headline.font
        }
    }
    private var hPad: CGFloat {
        switch controlSize {
        case .mini, .small: 12
        case .large, .extraLarge: 22
        default: 16
        }
    }

    /// Solid buttons have a lip; ghost buttons (and a destructive one at rest) are flat.
    private var hasLip: Bool {
        switch kind {
        case .primary, .secondary: true
        case .ghost: false
        case .destructive: isHovered && isEnabled
        }
    }

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        let lip = Lip.height(controlSize)
        let sink = hasLip && pressed ? lip * Lip.travel : 0
        configuration.label
            .labelStyle(StageButtonLabelStyle())
            .font(labelFont)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad)
            .frame(height: height)
            .frame(minWidth: height)
            .background { face(pressed: pressed) }
            .offset(y: sink)
            .background {
                if hasLip {
                    Capsule().fill(lipColor).offset(y: lip)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovered = $0 }
            .stageAnimation(Theme.Motion.quick, value: pressed)
            .stageAnimation(Theme.Motion.quick, value: isHovered)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .onTangerine
        case .secondary: .textPrimary
        case .ghost: isHovered ? .textPrimary : .textSecondary
        case .destructive: isHovered && isEnabled ? .white : .cherryInk
        }
    }

    private var lipColor: Color {
        switch kind {
        case .primary: .tangerineDeep
        case .secondary: Color.shadow.opacity(0.16)
        case .ghost: .clear
        case .destructive: .cherryDeep
        }
    }

    @ViewBuilder private func face(pressed: Bool) -> some View {
        let shape = Capsule()
        switch kind {
        case .primary:
            shape
                .fill(LinearGradient(colors: [Color.tangerineLight, .tangerine], startPoint: .top, endPoint: .bottom))
                .overlay(shape.inset(by: 0.5).stroke(.white.opacity(0.35), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                .brightness(pressed ? -0.03 : (isHovered ? 0.03 : 0))
        case .secondary:
            shape
                .fill(Color.surfaceRaised)
                .overlay(shape.inset(by: 0.5).stroke(isHovered ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
                .brightness(pressed ? -0.02 : 0)
        case .ghost:
            shape.fill(Color.textPrimary.opacity(pressed ? 0.09 : (isHovered ? 0.05 : 0)))
        case .destructive:
            if isHovered && isEnabled {
                shape.fill(Color.cherry).brightness(pressed ? -0.04 : 0)
            } else {
                shape
                    .fill(Color.cherry.opacity(0.09))
                    .overlay(shape.inset(by: 0.5).stroke(Color.cherry.opacity(0.4), lineWidth: 1))
            }
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

/// Round, icon-only button. Never tangerine: play / pause uses `.play(isPlaying:)`. The button's title is kept for VoiceOver; add `.help("…")` for a tooltip.
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

    /// The glyph drawn on a filled disc.
    private var onFill: Color {
        switch style.tone {
        case .neutral: .backdrop
        case .danger: .white
        default: .onTangerine
        }
    }

    var body: some View {
        let size = Theme.ControlHeight.of(controlSize)
        let pressed = configuration.isPressed
        let tint = style.tone == .neutral ? Color.textPrimary : style.tone.textColor
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(style.filled ? onFill : (isHovered ? tint : tint.opacity(style.tone == .neutral ? 0.72 : 0.92)))
            .frame(width: size, height: size)
            .background {
                if style.filled {
                    Circle()
                        .fill(style.tone == .neutral ? Color.textPrimary : style.tone.color)
                        .brightness(pressed ? -0.06 : (isHovered ? 0.04 : 0))
                } else {
                    Circle()
                        .fill(Color.textPrimary.opacity(pressed ? 0.1 : (isHovered ? 0.06 : 0)))
                }
            }
            .contentShape(Circle())
            .scaleEffect(pressed ? 0.88 : (isHovered ? 1.06 : 1))
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovered = $0 }
            .stageAnimation(Theme.Motion.quick, value: pressed)
            .stageAnimation(Theme.Motion.quick, value: isHovered)
    }
}

// MARK: - Play

/// Round transport button for play / pause. A white disc on a lip at rest; tangerine only while `isPlaying`.
/// Sized by `controlSize` like `IconButtonStyle`. The button's title is kept for VoiceOver.
///
///     Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill") { toggle() }
///         .buttonStyle(.play(isPlaying: isPlaying))
struct PlayButtonStyle: ButtonStyle {
    var isPlaying: Bool

    func makeBody(configuration: Configuration) -> some View {
        PlayButtonBody(isPlaying: isPlaying, configuration: configuration)
    }
}

private struct PlayButtonBody: View {
    let isPlaying: Bool
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let size = Theme.ControlHeight.of(controlSize)
        let pressed = configuration.isPressed && isEnabled
        let lip = Lip.height(controlSize) * 0.8
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(isPlaying ? Color.onTangerine : .textPrimary)
            .frame(width: size, height: size)
            .background {
                if isPlaying {
                    Circle()
                        .fill(LinearGradient(colors: [Color.tangerineLight, .tangerine], startPoint: .top, endPoint: .bottom))
                        .brightness(isHovered ? 0.03 : 0)
                } else {
                    Circle()
                        .fill(Color.surfaceRaised)
                        .overlay(Circle().strokeBorder(isHovered ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
                }
            }
            .offset(y: pressed ? lip * Lip.travel : 0)
            .background {
                Circle().fill(isPlaying ? Color.tangerineDeep : Color.shadow.opacity(0.16)).offset(y: lip)
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
            .stageAnimation(Theme.Motion.quick, value: pressed)
            .stageAnimation(Theme.Motion.quick, value: isHovered)
            .stageAnimation(Theme.Motion.standard, value: isPlaying)
    }
}

extension ButtonStyle where Self == StageButtonStyle {
    /// Tangerine primary action. One per screen, ideally.
    static var primary: StageButtonStyle { .init(kind: .primary) }
    /// Neutral raised button.
    static var secondary: StageButtonStyle { .init(kind: .secondary) }
    /// Text-only button for tertiary actions.
    static var ghost: StageButtonStyle { .init(kind: .ghost) }
    /// Cherry outline that fills (and grows a lip) on hover. For delete / discard.
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

extension ButtonStyle where Self == PlayButtonStyle {
    /// Transport button. White at rest; tangerine only while `isPlaying`.
    static func play(isPlaying: Bool) -> PlayButtonStyle {
        .init(isPlaying: isPlaying)
    }
}
