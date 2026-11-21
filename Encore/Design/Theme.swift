import AppKit
import SwiftUI

// MARK: - Design rules
//
// Encore is a dark stage with one light. The personality stays; each effect has one place to live.
//
// THE LIGHT (tungsten fill, tungsten glow)
//   Only three things are lit at a time:
//   1. where you are: the rail's selection lamp, a selected row's edge;
//   2. the next step: one primary button per screen (`.buttonStyle(.primary)`);
//   3. what is live: the thing playing (`.buttonStyle(.play(isPlaying:))`), recording or running.
//   Everything else is unlit: play buttons at rest, icons, category labels, secondary actions.
//   A list never has one lit thing per row.
//
// COLOR
//   Mint, footlight and velvet are states (done, needs attention, failed / destructive / recording), never
//   categories. Kinds of things (cloned / designed / imported, speech / transcript …) are told apart by icon
//   and word, in neutral text. Gel marks voice cues in scripts. Speaker colors exist only in Conversations.
//   Red text on the dark grounds uses `velvetText` (or `Tone.textColor`), which is readable; `velvet` is for fills.
//
// TYPE
//   Text uses a `TextRole`. Serif (`marquee`, `title`, `heading`) is for names on the bill: the screen title,
//   sheet and empty-state titles, voices, scripts. Section headings are `section` (sans). Mono is for numbers
//   and timecodes, not sentences. No font sizes outside the roles, except SF Symbol sizing.
//
// DECORATION
//   Grain: the window ground only. Warm wash: the stage panel only. Spotlight cone: full-screen empty states
//   only. Perforated tear line: only above the action row of a sheet. Elsewhere use `Hairline()` or space.
//   No dotted leaders, no glow on dots, icons or badges.
//
// WORDS
//   Theater words stay where there is room and nothing to operate: the rail groups, screen taglines,
//   empty-state titles, toasts. The working vocabulary is small: Perform (make speech), Audition (try designed
//   voices), Cast, Takes. Steps, field labels, status and errors are plain. No cue numbers ("Q1"), no
//   "company" in counts or labels.
//
// DENSITY
//   Say each fact once per screen. Engineering detail (precision names like bf16, runtimes, memory figures,
//   seeds, chunk counts, file paths) lives in a details view or a tooltip, and comes forward only when it
//   needs action. The primary action is always visible without scrolling.

// MARK: - Palette

/// The semantic color slots of an Encore theme.
///
/// Only `Palette.afterDark` exists today. Everything in the UI reads colors through the
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
    var hairline: UInt32          // base color for hairline borders (used with alpha)

    // Text
    var textPrimary: UInt32
    var textSecondary: UInt32
    var textTertiary: UInt32

    // Lights
    var tungsten: UInt32          // primary accent: warm amber stage light
    var tungstenDeep: UInt32      // the darker end of tungsten gradients
    var onTungsten: UInt32        // text/icons drawn on a tungsten fill
    var velvet: UInt32            // recording and destructive (fills, borders, lamps)
    var velvetDeep: UInt32
    var velvetText: UInt32        // velvet for text on the dark grounds (4.5:1 and up)
    var mint: UInt32              // ready / success
    var footlight: UInt32         // warnings (an orange that stays distinct from tungsten)
    var gel: UInt32               // a lavender lighting gel: voice cues (voice-switch tags), distinct from every other light

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
        textTertiary: 0x8F857A,   // 4.9:1 on `surface`; the smallest text stays readable
        tungsten: 0xFFB648,
        tungstenDeep: 0xE0821C,
        onTungsten: 0x1C1206,
        velvet: 0xD7263D,
        velvetDeep: 0x8C1426,
        velvetText: 0xEB5A5F,
        mint: 0x7FD1C7,
        footlight: 0xF2874E,
        gel: 0xC9A7FF
    )

    /// The palette the app renders with.
    static let active = Palette.afterDark
}

extension Color {
    /// Creates a color from a 24-bit `0xRRGGBB` value.
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

// MARK: - Color tokens

/// Semantic color tokens. Use these everywhere (`.foregroundStyle(.textSecondary)`,
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
    /// Border for hovered / emphasized controls.
    static let hairlineStrong = Color(hex: p.hairline, opacity: 0.18)

    static let textPrimary = Color(hex: p.textPrimary)
    static let textSecondary = Color(hex: p.textSecondary)
    static let textTertiary = Color(hex: p.textTertiary)

    static let tungsten = Color(hex: p.tungsten)
    static let tungstenDeep = Color(hex: p.tungstenDeep)
    static let onTungsten = Color(hex: p.onTungsten)
    static let velvet = Color(hex: p.velvet)
    static let velvetDeep = Color(hex: p.velvetDeep)
    /// Velvet for text and small glyphs on the dark grounds.
    static let velvetText = Color(hex: p.velvetText)
    static let mint = Color(hex: p.mint)
    static let footlight = Color(hex: p.footlight)
    /// Voice cues: voice-switch tags and the chips that insert them.
    static let gel = Color(hex: p.gel)
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
    static var velvetText: Color { .velvetText }
    static var mint: Color { .mint }
    static var footlight: Color { .footlight }
    static var gel: Color { .gel }
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

    /// The tone as text or a small glyph on the dark grounds (danger uses the readable red).
    var textColor: Color { self == .danger ? .velvetText : color }

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

/// `withAnimation` that honors Reduce Motion. Use from button actions.
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
