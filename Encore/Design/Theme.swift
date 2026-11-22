import AppKit
import SwiftUI

// MARK: - Design rules
//
// Encore is cream and cocoa, set in Allo: warm, round and a little bit cheeky. Friendly never means busy;
// each effect has one place to live.
//
// THE POP (tangerine)
//   Only three things pop at a time:
//   1. where you are: the rail's selected pill, a selected row;
//   2. the next step: one primary button per screen (`.buttonStyle(.primary)`);
//   3. what is live: the thing playing (`.buttonStyle(.play(isPlaying:))`), recording or running.
//   Everything else stays cream: play buttons at rest, icons, category labels, secondary actions.
//   A list never has one tangerine thing per row.
//
// COLOR
//   Matcha, honey and cherry are states (done, needs attention, failed / destructive / recording), never
//   categories. Kinds of things (cloned / designed / imported, speech / transcript …) are told apart by icon
//   and word, in neutral text. Lilac marks voice cues in scripts. Speaker colors exist only in Conversations.
//   Each flavor has a bright fill (`tangerine`, `matcha`, …) and an ink for text and small glyphs on cream
//   (`tangerineInk`, `matchaInk`, …, or `Tone.textColor`). Fills never carry small text on cream.
//
// SHAPE & DEPTH
//   Corners are generous; buttons, chips, toggles and search are capsules. Things you press have a lip: a
//   darker edge underneath that squashes when pressed. Cards float on a soft cocoa shadow, wells are sunk
//   into cream. No glows: light comes from color, not from haze.
//
// TYPE
//   Text uses a `TextRole`, all in Allo. The round display cut (`marquee`, `title`, `heading`) is for names:
//   the screen title, sheet and empty-state titles, voices, scripts. Section headings are `section`. Numeric
//   roles (`readout`, `mono`, `monoSmall`) use Allo's tabular figures, for numbers and timecodes, not
//   sentences. No font sizes outside the roles, except SF Symbol sizing.
//
// DECORATION
//   Paper grain: the window ground only. Blush: the stage panel's top corner only. The sticker (a tilted tile
//   with sprinkles): full-screen empty states only. The squiggle: only above the action row of a sheet.
//   Elsewhere use `Hairline()` or space.
//
// WORDS
//   Warm and plain, like a friend who knows sound. Theater words stay where there is room and nothing to
//   operate: the rail groups, screen taglines, empty-state titles, toasts. The working vocabulary is small:
//   Perform (make speech), Audition (try designed voices), Cast, Takes. Steps, field labels, status and
//   errors are plain. No cue numbers ("Q1"), no "company" in counts or labels, no exclamation marks in errors.
//
// DENSITY
//   Say each fact once per screen. Engineering detail (precision names like bf16, runtimes, memory figures,
//   seeds, chunk counts, file paths) lives in a details view or a tooltip, and comes forward only when it
//   needs action. The primary action is always visible without scrolling.

// MARK: - Palette

/// The semantic color slots of an Encore theme.
///
/// Everything in the UI reads colors through the `Color` tokens below (`.backdrop`, `.textPrimary`,
/// `.tangerine`, …), never through raw hex values, so a palette can be swapped by changing
/// `Palette.active` without touching any view.
struct Palette: Sendable {
    // Grounds
    var backdrop: UInt32          // window ground: cream
    var rail: UInt32              // sidebar rail (sits on the cream)
    var stage: UInt32             // the milk panel screens sit on
    var surface: UInt32           // cards and panels
    var surfaceRaised: UInt32     // controls, popovers, things on top of cards
    var surfaceSunken: UInt32     // input wells, tracks
    var hairline: UInt32          // base color for hairline borders and shadows (used with alpha)

    // Text
    var textPrimary: UInt32
    var textSecondary: UInt32
    var textTertiary: UInt32

    // Flavors: a fill and an ink (text and small glyphs on cream, 4.5:1 and up on the stage)
    var tangerine: UInt32         // primary accent
    var tangerineLight: UInt32    // the lighter top of its gradients
    var peach: UInt32             // a soft tangerine tint for stickers and selected pills
    var peachLight: UInt32
    var tangerineDeep: UInt32     // its lip and the darker end of its gradients
    var tangerineInk: UInt32
    var onTangerine: UInt32       // text/icons drawn on a tangerine fill
    var cherry: UInt32            // recording and destructive (fills, borders, dots)
    var cherryDeep: UInt32
    var cherryInk: UInt32
    var matcha: UInt32            // ready / success
    var matchaInk: UInt32
    var honey: UInt32             // warnings
    var honeyInk: UInt32
    var lilac: UInt32             // voice cues (voice-switch tags), distinct from every other flavor
    var lilacInk: UInt32

    /// The one authored theme: fresh cream.
    static let cream = Palette(
        backdrop: 0xF3E9D9,
        rail: 0xF3E9D9,
        stage: 0xFCF7EF,
        surface: 0xFFFCF7,
        surfaceRaised: 0xFFFFFF,
        surfaceSunken: 0xF4ECDF,
        hairline: 0x4A3022,
        textPrimary: 0x2B1D14,
        textSecondary: 0x6B5546,
        textTertiary: 0x7D6757,   // 4.9:1 on `stage`; the smallest text stays readable
        tangerine: 0xFF7A2F,
        tangerineLight: 0xFF9A5C,
        peach: 0xFFCBA6,
        peachLight: 0xFFE6D2,
        tangerineDeep: 0xE2560F,
        tangerineInk: 0xB8440A,
        onTangerine: 0x2A1206,
        cherry: 0xEC4F5A,
        cherryDeep: 0xC23441,
        cherryInk: 0xBF2C3A,
        matcha: 0x56B37A,
        matchaInk: 0x2A7A4B,
        honey: 0xF6B93B,
        honeyInk: 0x8F6100,
        lilac: 0xA284F2,
        lilacInk: 0x6A4BCB
    )

    /// The palette the app renders with.
    static let active = Palette.cream
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
    static let hairline = Color(hex: p.hairline, opacity: 0.11)
    /// Border for hovered / emphasized controls.
    static let hairlineStrong = Color(hex: p.hairline, opacity: 0.2)
    /// Warm shadow color: cocoa, never black.
    static let shadow = Color(hex: p.hairline)

    static let textPrimary = Color(hex: p.textPrimary)
    static let textSecondary = Color(hex: p.textSecondary)
    static let textTertiary = Color(hex: p.textTertiary)

    static let tangerine = Color(hex: p.tangerine)
    static let tangerineLight = Color(hex: p.tangerineLight)
    static let peach = Color(hex: p.peach)
    static let peachLight = Color(hex: p.peachLight)
    static let tangerineDeep = Color(hex: p.tangerineDeep)
    /// Tangerine for text and small glyphs on cream.
    static let tangerineInk = Color(hex: p.tangerineInk)
    static let onTangerine = Color(hex: p.onTangerine)
    static let cherry = Color(hex: p.cherry)
    static let cherryDeep = Color(hex: p.cherryDeep)
    /// Cherry for text and small glyphs on cream.
    static let cherryInk = Color(hex: p.cherryInk)
    static let matcha = Color(hex: p.matcha)
    static let matchaInk = Color(hex: p.matchaInk)
    static let honey = Color(hex: p.honey)
    static let honeyInk = Color(hex: p.honeyInk)
    /// Voice cues: voice-switch tags and the chips that insert them.
    static let lilac = Color(hex: p.lilac)
    static let lilacInk = Color(hex: p.lilacInk)
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
    static var tangerine: Color { .tangerine }
    static var tangerineLight: Color { .tangerineLight }
    static var peach: Color { .peach }
    static var peachLight: Color { .peachLight }
    static var tangerineDeep: Color { .tangerineDeep }
    static var tangerineInk: Color { .tangerineInk }
    static var onTangerine: Color { .onTangerine }
    static var cherry: Color { .cherry }
    static var cherryDeep: Color { .cherryDeep }
    static var cherryInk: Color { .cherryInk }
    static var matcha: Color { .matcha }
    static var matchaInk: Color { .matchaInk }
    static var honey: Color { .honey }
    static var honeyInk: Color { .honeyInk }
    static var lilac: Color { .lilac }
    static var lilacInk: Color { .lilacInk }
}

// MARK: - Tone

/// The semantic intent of a badge, banner, toast or chip.
enum Tone: Sendable, Hashable {
    case neutral
    /// Tangerine: highlighted / in focus.
    case accent
    /// Matcha: ready, done, success.
    case success
    /// Honey: needs attention.
    case warning
    /// Cherry: failed, destructive, recording.
    case danger

    /// The tone as a fill (dots, bars, tints).
    var color: Color {
        switch self {
        case .neutral: .textSecondary
        case .accent: .tangerine
        case .success: .matcha
        case .warning: .honey
        case .danger: .cherry
        }
    }

    /// The tone as text or a small glyph on cream.
    var textColor: Color {
        switch self {
        case .neutral: .textSecondary
        case .accent: .tangerineInk
        case .success: .matchaInk
        case .warning: .honeyInk
        case .danger: .cherryInk
        }
    }

    /// Default SF Symbol for banners and toasts.
    var symbol: String {
        switch self {
        case .neutral: "info.circle.fill"
        case .accent: "sparkles"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
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

    /// Corner radii. Encore is soft: corners are generous, and pressable things are capsules.
    enum Radius {
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
    }

    /// Standard control heights per `ControlSize`.
    enum ControlHeight {
        static let small: CGFloat = 26
        static let regular: CGFloat = 32
        static let large: CGFloat = 40

        static func of(_ size: ControlSize) -> CGFloat {
            switch size {
            case .mini, .small: small
            case .large, .extraLarge: large
            default: regular
            }
        }
    }

    /// Motion tokens: springy and quick, with a little bounce.
    enum Motion {
        /// Hover, press, small state flips.
        static let quick = Animation.spring(duration: 0.2, bounce: 0.2)
        /// Selection moves, thumbs, expanding panels.
        static let standard = Animation.spring(duration: 0.36, bounce: 0.28)
        /// Things that enter: toasts, sheets, banners.
        static let entrance = Animation.spring(duration: 0.5, bounce: 0.36)
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
    /// A soft, colored puff of shadow under the view. Used for the primary action and recording indicators,
    /// where a tinted shadow reads as the color spilling onto the cream.
    func glow(_ color: Color = .tangerine, radius: CGFloat = 10, intensity: Double = 0.5) -> some View {
        self.shadow(color: color.opacity(intensity * 0.55), radius: radius * 0.8, y: radius * 0.35)
    }

    /// The resting shadow of a card on the stage: barely there, warm.
    func lift() -> some View {
        self
            .shadow(color: Color.shadow.opacity(0.05), radius: 1, y: 1)
            .shadow(color: Color.shadow.opacity(0.06), radius: 12, y: 5)
    }

    /// Drop shadow for things that float above the stage (popovers, toasts, sheets).
    func elevation() -> some View {
        self
            .shadow(color: Color.shadow.opacity(0.1), radius: 1.5, y: 1)
            .shadow(color: Color.shadow.opacity(0.16), radius: 26, y: 14)
    }
}
