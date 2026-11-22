import AppKit
import CoreText
import SwiftUI

// MARK: - Faces

/// Encore is set in Allo (Josh Puckett, SIL OFL 1.1), a friendly rounded remix of Inter, bundled as one
/// variable font (`Resources/Fonts/AlloVariable.ttf`). Its three axes are set per use: weight, optical size
/// (follows the point size) and roundness. Display text uses the fully round cut, UI text the default
/// "friendly" cut. Numbers use Allo's tabular figures. Everything falls back to the system font if the
/// file is missing.
extension Font {
    /// Round display cut for titles and names. Use at 18pt and above.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        AlloFont.font(size: size, weight: weight, roundness: 100)
            ?? .system(size: size, weight: weight, design: .rounded)
    }

    /// Allo UI text.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        AlloFont.font(size: size, weight: weight, roundness: 50)
            ?? .system(size: size, weight: weight)
    }

    /// Numbers, timecodes and parameter values: Allo with tabular figures.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        AlloFont.font(size: size, weight: weight, roundness: 50, tabular: true)
            ?? .system(size: size, weight: weight, design: .monospaced)
    }
}

extension NSFont {
    /// Allo UI text for AppKit text views.
    @MainActor static func allo(_ size: CGFloat, weight: Font.Weight = .regular) -> NSFont {
        AlloFont.nsFont(size: size, weight: weight, roundness: 50) ?? .systemFont(ofSize: size)
    }
}

enum AlloFont {
    private static let postScriptName = "AlloVariable-Regular"

    /// Registers the bundled font with this process. Call once, before any view draws.
    static func register() {
        guard let url = Bundle.main.url(forResource: "AlloVariable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private struct Key: Hashable {
        var size: CGFloat, weight: CGFloat, roundness: CGFloat, tabular: Bool
    }
    @MainActor private static var cache: [Key: CTFont] = [:]
    @MainActor private static var isAvailable: Bool = NSFont(name: postScriptName, size: 12) != nil

    @MainActor static func font(size: CGFloat, weight: Font.Weight, roundness: CGFloat, tabular: Bool = false) -> Font? {
        ctFont(size: size, weight: weight, roundness: roundness, tabular: tabular).map { Font($0) }
    }

    @MainActor static func nsFont(size: CGFloat, weight: Font.Weight, roundness: CGFloat) -> NSFont? {
        ctFont(size: size, weight: weight, roundness: roundness, tabular: false) as NSFont?
    }

    @MainActor private static func ctFont(size: CGFloat, weight: Font.Weight, roundness: CGFloat, tabular: Bool) -> CTFont? {
        guard isAvailable else { return nil }
        let key = Key(size: size, weight: wght(weight), roundness: roundness, tabular: tabular)
        if let cached = cache[key] { return cached }

        var attributes: [CFString: Any] = [
            kCTFontNameAttribute: postScriptName,
            kCTFontVariationAttribute: [
                tag("wght"): key.weight,
                tag("opsz"): min(max(size, 9), 32),
                tag("ROND"): roundness,
            ] as [UInt32: CGFloat],
        ]
        if tabular {
            attributes[kCTFontFeatureSettingsAttribute] = [
                [kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1],
            ]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        cache[key] = font
        return font
    }

    private static func wght(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: 200
        case .thin: 250
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    private static func tag(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - Text roles

/// Semantic text roles. Apply with `.textRole(.body)`; the role sets face, size, tracking and
/// a default color (pass `color:` to override it).
///
/// These are all the text sizes in the app: display 30 / 24 / 19, text 15 / 13 / 12 / 11, numerals 24 / 12 / 11.
/// Don't write `.font(.ui(…))`, `.font(.mono(…))` or `.font(.display(…))` in a view; pick a role. (Sizing an
/// SF Symbol with `.font(.system(size:))` is fine.) The round display cut is for names; see the design rules
/// in Theme.swift.
enum TextRole: CaseIterable, Sendable {
    /// The screen title in the scaffold. Round Allo ExtraBold, 30pt.
    case marquee
    /// Sheet titles, empty-state titles. Round Allo Bold, 24pt.
    case title
    /// The name of a voice or a script, where it is the subject of a card or panel. Round Allo Bold, 19pt.
    /// Not for section headings: use `section`.
    case heading
    /// Section headings inside a screen or sheet ("Variants", "Cast", "Earlier"). Allo Bold 15.
    case section
    /// Emphasized UI text: row titles, control labels that matter. Allo SemiBold 13.
    case headline
    /// The words being written or read at length: scripts, transcripts, descriptions in an editor. Allo Regular 15.
    case script
    /// Default reading text. Allo Regular 13.
    case body
    /// Control labels. Allo Medium 12.
    case label
    /// Secondary explanatory text. Allo Regular 12, secondary color.
    case caption
    /// Small label above things ("Advanced", group names in the rail). Allo Bold 11, sentence case.
    case eyebrow
    /// A large numeric readout: the recorder's clock, a trim length. Allo SemiBold 24, tabular.
    case readout
    /// Parameter values, numerics. Allo Medium 12, tabular.
    case mono
    /// Small numerics: timecodes in lists, sizes. Allo Medium 11, tabular.
    case monoSmall

    var font: Font {
        switch self {
        case .marquee: .display(30, weight: .heavy)
        case .title: .display(24)
        case .heading: .display(19)
        case .section: .ui(15, weight: .bold)
        case .headline: .ui(13, weight: .semibold)
        case .script: .ui(15)
        case .body: .ui(13)
        case .label: .ui(12, weight: .medium)
        case .caption: .ui(12)
        case .eyebrow: .ui(11, weight: .bold)
        case .readout: .mono(24, weight: .semibold)
        case .mono: .mono(12, weight: .medium)
        case .monoSmall: .mono(11, weight: .medium)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .marquee: -0.6
        case .title: -0.4
        case .heading: -0.2
        case .eyebrow: 0.3
        default: 0
        }
    }

    var color: Color {
        switch self {
        case .caption: .textSecondary
        case .eyebrow: .textTertiary
        default: .textPrimary
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .script: 5
        case .body: 3
        case .caption: 2
        default: 0
        }
    }
}

extension View {
    /// Applies an Encore text role: face, size, tracking, line spacing and color (the role's
    /// default unless `color` is given). A `.foregroundStyle` applied after this will NOT
    /// override the color (the innermost style wins), so pass `color:` instead.
    func textRole(_ role: TextRole, color: Color? = nil) -> some View {
        self
            .font(role.font)
            .tracking(role.tracking)
            .lineSpacing(role.lineSpacing)
            .foregroundStyle(color ?? role.color)
    }
}
