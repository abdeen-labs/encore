import AppKit
import SwiftUI

// MARK: - Palette

/// The semantic colour slots of an Encore theme.
///
/// Only `Palette.afterDark` exists today. Everything in the UI reads colours through the
/// `Color` tokens below (`.backdrop`, `.textPrimary`, `.tungsten`, …), never through raw
/// hex values, so a second palette can be introduced later by swapping `Palette.active`
/// (or making the tokens appearance-dynamic) without touching any view.
struct Palette: Sendable {
    // Grounds
    var backdrop: UInt32          // window ground: warm near-black ink
    var rail: UInt32              // sidebar rail, a breath lighter than the backdrop
    var stage: UInt32             // the lit panel screens play on
    var surface: UInt32           // cards and panels
    var surfaceRaised: UInt32     // controls, popovers, things on top of cards
    var surfaceSunken: UInt32     // input wells, tracks
    var hairline: UInt32          // base colour for hairline borders (used with alpha)

    // Text
    var textPrimary: UInt32
    var textSecondary: UInt32
    var textTertiary: UInt32

    // Lights
    var tungsten: UInt32          // primary accent: warm amber stage light
    var tungstenDeep: UInt32      // the darker end of tungsten gradients
    var onTungsten: UInt32        // text/icons drawn on a tungsten fill
    var velvet: UInt32            // recording and destructive
    var velvetDeep: UInt32
    var mint: UInt32              // ready / success
    var footlight: UInt32         // warnings (an orange that stays distinct from tungsten)

    /// The one authored theme: the stage after dark.
    static let afterDark = Palette(
        backdrop: 0x0E0C0B,
        rail: 0x12100E,
        stage: 0x14110F,
        surface: 0x1A1715,
        surfaceRaised: 0x24201C,
        surfaceSunken: 0x0A0908,
        hairline: 0xF4EDE4,
        textPrimary: 0xF4EDE4,
        textSecondary: 0xA99E92,
        textTertiary: 0x6F665D,
        tungsten: 0xFFB648,
        tungstenDeep: 0xE0821C,
        onTungsten: 0x1C1206,
        velvet: 0xD7263D,
        velvetDeep: 0x8C1426,
        mint: 0x7FD1C7,
        footlight: 0xF2874E
    )

    /// The palette the app renders with.
    static let active = Palette.afterDark
}

extension Color {
    /// Creates a colour from a 24-bit `0xRRGGBB` value.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Colour tokens

/// Semantic colour tokens. Use these everywhere (`.foregroundStyle(.textSecondary)`,
/// `.background(Color.surface)`), never hex literals.
extension Color {
    private static var p: Palette { Palette.active }

    static let backdrop = Color(hex: p.backdrop)
    static let rail = Color(hex: p.rail)
    static let stage = Color(hex: p.stage)
    static let surface = Color(hex: p.surface)
    static let surfaceRaised = Color(hex: p.surfaceRaised)
    static let surfaceSunken = Color(hex: p.surfaceSunken)
    /// Default 1px border on surfaces and controls.
    static let hairline = Color(hex: p.hairline, opacity: 0.09)
    /// Border for hovered / emphasised controls.
    static let hairlineStrong = Color(hex: p.hairline, opacity: 0.18)

    static let textPrimary = Color(hex: p.textPrimary)
    static let textSecondary = Color(hex: p.textSecondary)
    static let textTertiary = Color(hex: p.textTertiary)

    static let tungsten = Color(hex: p.tungsten)
    static let tungstenDeep = Color(hex: p.tungstenDeep)
    static let onTungsten = Color(hex: p.onTungsten)
    static let velvet = Color(hex: p.velvet)
    static let velvetDeep = Color(hex: p.velvetDeep)
    static let mint = Color(hex: p.mint)
    static let footlight = Color(hex: p.footlight)
}

extension ShapeStyle where Self == Color {
    static var backdrop: Color { .backdrop }
    static var rail: Color { .rail }
    static var stage: Color { .stage }
    static var surface: Color { .surface }
    static var surfaceRaised: Color { .surfaceRaised }
    static var surfaceSunken: Color { .surfaceSunken }
    static var hairline: Color { .hairline }
    static var hairlineStrong: Color { .hairlineStrong }
    static var textPrimary: Color { .textPrimary }
    static var textSecondary: Color { .textSecondary }
    static var textTertiary: Color { .textTertiary }
    static var tungsten: Color { .tungsten }
    static var tungstenDeep: Color { .tungstenDeep }
    static var onTungsten: Color { .onTungsten }
    static var velvet: Color { .velvet }
    static var velvetDeep: Color { .velvetDeep }
    static var mint: Color { .mint }
    static var footlight: Color { .footlight }
}

// MARK: - Tone

/// The semantic intent of a badge, banner, toast or chip.
enum Tone: Sendable, Hashable {
    case neutral
    /// Tungsten: highlighted / in focus.
    case accent
    /// Mint: ready, done, success.
    case success
    /// Footlight orange: needs attention.
    case warning
    /// Velvet: failed, destructive, recording.
    case danger

    var color: Color {
        switch self {
        case .neutral: .textSecondary
        case .accent: .tungsten
        case .success: .mint
        case .warning: .footlight
        case .danger: .velvet
        }
    }

    /// Default SF Symbol for banners and toasts.
    var symbol: String {
        switch self {
        case .neutral: "info.circle"
        case .accent: "sparkle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        }
    }
}

// MARK: - Metrics

/// Layout and shape tokens.
enum Theme {
    /// Spacing scale, in points. Prefer these over literals.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        /// Horizontal inset of screen content from the window edges.
        static let screenInset: CGFloat = 40
    }

    /// Corner radii. Encore uses fairly tight corners: it is a stage, not a bubble bath.
    enum Radius {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 9
        static let l: CGFloat = 14
        static let xl: CGFloat = 20
    }

    /// Standard control heights per `ControlSize`.
    enum ControlHeight {
        static let small: CGFloat = 24
        static let regular: CGFloat = 30
        static let large: CGFloat = 38

        static func of(_ size: ControlSize) -> CGFloat {
            switch size {
            case .mini, .small: small
            case .large, .extraLarge: large
            default: regular
            }
        }
    }

    /// Motion tokens: quick, physical, restrained.
    enum Motion {
        /// Hover, press, small state flips.
        static let quick = Animation.spring(duration: 0.16, bounce: 0.0)
        /// Selection moves, thumbs, expanding panels.
        static let standard = Animation.spring(duration: 0.3, bounce: 0.12)
        /// Things that enter the stage: toasts, sheets, banners.
        static let entrance = Animation.spring(duration: 0.42, bounce: 0.18)
        /// Fallback used instead of movement when Reduce Motion is on.
        static let reduced = Animation.easeInOut(duration: 0.12)
    }
}

// MARK: - Motion helpers

extension EnvironmentValues {
    /// True while the app renders headless snapshots; animated components draw a still frame.
    @Entry var isSnapshotting: Bool = false
}

private struct StageAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotting) private var isSnapshotting
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(isSnapshotting ? nil : (reduceMotion ? Theme.Motion.reduced : animation), value: value)
    }
}

extension View {
    /// Like `.animation(_:value:)`, but swaps movement for a short fade when Reduce Motion is
    /// on, and disables animation while snapshotting.
    func stageAnimation<V: Equatable>(_ animation: Animation = Theme.Motion.standard, value: V) -> some View {
        modifier(StageAnimationModifier(animation: animation, value: value))
    }
}

/// `withAnimation` that honours Reduce Motion. Use from button actions.
@discardableResult
func withStageAnimation<Result>(_ animation: Animation = Theme.Motion.standard, _ body: () throws -> Result) rethrows -> Result {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    return try withAnimation(reduce ? Theme.Motion.reduced : animation, body)
}

// MARK: - Glow & elevation

extension View {
    /// A soft halo of light around the view, like a lamp catching haze. Used for the lit nav
    /// item, the primary action and recording indicators.
    func glow(_ color: Color = .tungsten, radius: CGFloat = 10, intensity: Double = 0.5) -> some View {
        self
            .shadow(color: color.opacity(intensity * 0.9), radius: radius * 0.35)
            .shadow(color: color.opacity(intensity * 0.55), radius: radius)
    }

    /// Drop shadow for things that float above the stage (popovers, toasts, sheets).
    func elevation() -> some View {
        self
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }
}
