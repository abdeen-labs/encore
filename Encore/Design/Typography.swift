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
/// a default color (override color with `.foregroundStyle` after it if needed).
enum TextRole: CaseIterable, Sendable {
    /// Screen titles in the scaffold. Display serif, 40pt.
    case marquee
    /// Sheet titles, empty-state titles. Display serif, 26pt.
    case title
    /// Card titles and section headings. Display serif, 19pt.
    case heading
    /// Emphasized UI text: row titles, control labels that matter. Avenir Next DemiBold 13.
    case headline
    /// Default reading text. Avenir Next Regular 13.
    case body
    /// Control labels. Avenir Next Medium 12.
    case label
    /// Secondary explanatory text. Avenir Next Regular 11.5, secondary color.
    case caption
    /// Small uppercase tracked label above things ("ADVANCED", group names in the rail).
    case eyebrow
    /// Parameter values, numerics. SF Mono 12.
    case mono
    /// Small numerics: timecodes in lists, readouts. SF Mono 10.5.
    case monoSmall

    var font: Font {
        switch self {
        case .marquee: .display(40)
        case .title: .display(26)
        case .heading: .display(19)
        case .headline: .ui(13, weight: .semibold)
        case .body: .ui(13)
        case .label: .ui(12, weight: .medium)
        case .caption: .ui(11.5)
        case .eyebrow: .ui(10, weight: .semibold)
        case .mono: .mono(12)
        case .monoSmall: .mono(10.5)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .marquee: -0.4
        case .title: -0.2
        case .eyebrow: 1.6
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
