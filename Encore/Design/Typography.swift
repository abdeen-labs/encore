import AppKit
import SwiftUI

// MARK: - Faces

/// Font faces. Display is a high-contrast theatrical serif (playbill); UI text is Avenir Next;
/// numerics, timecodes and parameter values are monospaced (SF Mono). Every face falls back
/// to a system design if it is missing on the machine.
extension Font {
    /// Theatrical display serif for titles. Use at 18pt and above.
    static func display(_ size: CGFloat, italic: Bool = false) -> Font {
        let candidates = italic
            ? ["BodoniSvtyTwoITCTT-BookIta", "Didot-Italic"]
            : ["BodoniSvtyTwoITCTT-Book", "Didot"]
        if let name = FontResolver.first(available: candidates) {
            return .custom(name, fixedSize: size)
        }
        let fallback = Font.system(size: size, weight: .regular, design: .serif)
        return italic ? fallback.italic() : fallback
    }

    /// Avenir Next UI text.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String = switch weight {
        case .ultraLight, .thin, .light: "AvenirNext-UltraLight"
        case .medium: "AvenirNext-Medium"
        case .semibold: "AvenirNext-DemiBold"
        case .bold: "AvenirNext-Bold"
        case .heavy, .black: "AvenirNext-Heavy"
        default: "AvenirNext-Regular"
        }
        if FontResolver.first(available: [name]) != nil {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: weight)
    }

    /// Monospaced face for numbers, timecodes and parameter values (tabular by nature).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum FontResolver {
    @MainActor private static var cache: [String: Bool] = [:]

    /// The first PostScript name in `names` that is installed.
    @MainActor static func first(available names: [String]) -> String? {
        for name in names {
            if let known = cache[name] {
                if known { return name } else { continue }
            }
            let ok = NSFont(name: name, size: 12) != nil
            cache[name] = ok
            if ok { return name }
        }
        return nil
    }
}

// MARK: - Text roles

/// Semantic text roles. Apply with `.textRole(.body)`; the role sets face, size, tracking and
/// a default color (pass `color:` to override it).
///
/// These are all the text sizes in the app: serif 28 / 24 / 19, sans 15 / 13 / 12 / 11, mono 22 / 12 / 11.
/// Don't write `.font(.ui(…))`, `.font(.mono(…))` or `.font(.display(…))` in a view; pick a role. (Sizing an
/// SF Symbol with `.font(.system(size:))` is fine.) Serif is for names on the bill; see the design rules in
/// Theme.swift.
enum TextRole: CaseIterable, Sendable {
    /// The screen title in the scaffold. Display serif, 28pt.
    case marquee
    /// Sheet titles, empty-state titles. Display serif, 24pt.
    case title
    /// The name of a voice or a script, where it is the subject of a card or panel. Display serif, 19pt.
    /// Not for section headings: use `section`.
    case heading
    /// Section headings inside a screen or sheet ("Variants", "Cast", "Earlier"). Avenir Next DemiBold 15.
    case section
    /// Emphasized UI text: row titles, control labels that matter. Avenir Next DemiBold 13.
    case headline
    /// The words being written or read at length: scripts, transcripts, descriptions in an editor. Avenir Next Regular 15.
    case script
    /// Default reading text. Avenir Next Regular 13.
    case body
    /// Control labels. Avenir Next Medium 12.
    case label
    /// Secondary explanatory text. Avenir Next Regular 12, secondary color.
    case caption
    /// Small uppercase tracked label above things ("ADVANCED", group names in the rail). Avenir Next DemiBold 11.
    case eyebrow
    /// A large numeric readout: the recorder's clock, a trim length. SF Mono Medium 22.
    case readout
    /// Parameter values, numerics. SF Mono 12.
    case mono
    /// Small numerics: timecodes in lists, sizes. SF Mono 11.
    case monoSmall

    var font: Font {
        switch self {
        case .marquee: .display(28)
        case .title: .display(24)
        case .heading: .display(19)
        case .section: .ui(15, weight: .semibold)
        case .headline: .ui(13, weight: .semibold)
        case .script: .ui(15)
        case .body: .ui(13)
        case .label: .ui(12, weight: .medium)
        case .caption: .ui(12)
        case .eyebrow: .ui(11, weight: .semibold)
        case .readout: .mono(22, weight: .medium)
        case .mono: .mono(12)
        case .monoSmall: .mono(11)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .marquee: -0.3
        case .title: -0.2
        case .eyebrow: 1.2
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

    var isUppercase: Bool { self == .eyebrow }
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
            .textCase(role.isUppercase ? .uppercase : nil)
    }
}
