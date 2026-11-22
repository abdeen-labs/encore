import EncoreCore
import SwiftUI

/// One voice as a card: the name in the display face, one caption line (origin icon, origin, language, length),
/// up to three tags, and the reference clip on a compact player. A tangerine border while it is open in the
/// inspector or checked for a batch action.
struct VoiceCard: View {
    let voice: Voice
    let reference: URL?
    var isFocused: Bool
    var isSelected: Bool
    var showsCheck: Bool
    var onClick: () -> Void
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(voice.name)
                .textRole(.heading)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.trailing, 22)
            facts.padding(.top, 2)
            tagLine.padding(.top, 2)
            player.padding(.top, Theme.Space.s)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { shape.fill(Color.surface) }
        .overlay {
            shape.strokeBorder(isFocused || isSelected ? Color.tangerine.opacity(isFocused ? 0.85 : 0.55)
                               : (isHovered ? Color.hairlineStrong : Color.hairline), lineWidth: isFocused ? 1.5 : 1)
        }
        .overlay(alignment: .topTrailing) { check.padding(Theme.Space.xs) }
        .contentShape(shape)
        .onTapGesture(perform: onClick)
        .onHover { isHovered = $0 }
        .stageAnimation(Theme.Motion.quick, value: isFocused)
        .stageAnimation(Theme.Motion.quick, value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(voice.name), \(voice.origin.label) voice")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(voice.transcript.isEmpty ? voice.name : "“\(voice.transcript)”")
    }

    /// "Cloned · English · 9 s", after a small neutral origin icon.
    private var facts: some View {
        HStack(spacing: 5) {
            Image(systemName: voice.origin.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            Text(factsLine).textRole(.caption).lineLimit(1)
        }
    }

    private var factsLine: String {
        var parts = [voice.origin.label]
        if let l = voice.language, !l.isEmpty { parts.append(VoiceLanguages.name(l)) }
        parts.append("\(max(1, Int(voice.duration.rounded()))) s")
        return parts.joined(separator: " · ")
    }

    /// Up to three tags as plain text; the line keeps its height when there are none, so cards in a row line up.
    private var tagLine: some View {
        let shown = voice.tags.prefix(3)
        let more = voice.tags.count - shown.count
        let text = shown.joined(separator: ", ") + (more > 0 ? " +\(more)" : "")
        return Text(text.isEmpty ? " " : text)
            .textRole(.caption, color: .textTertiary)
            .lineLimit(1)
            .accessibilityHidden(text.isEmpty)
    }

    @ViewBuilder private var player: some View {
        if let reference {
            WaveformPlayer(url: reference, title: voice.name, style: .compact)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tone.warning.textColor)
                Text("Reference clip missing").textRole(.caption)
            }
            .frame(height: 38)
        }
    }

    /// A round tick for multi-select: shown on hover, and always while voices are being picked. Clicking it
    /// checks this card (starting a multi-selection) or unchecks it.
    private var check: some View {
        Button(action: onToggle) {
            ZStack {
                Circle().fill(isSelected ? Color.tangerine : Color.surfaceSunken.opacity(0.9))
                Circle().strokeBorder(isSelected ? Color.tangerine : Color.textTertiary.opacity(0.7), lineWidth: 1.2)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Color.onTangerine)
                }
            }
            .frame(width: 18, height: 18)
            // A generous target around the small circle, so a near miss doesn't fall through to the card.
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isSelected || showsCheck || isHovered ? 1 : 0)
        .help(isSelected ? "Deselect" : "Select for export or delete (or ⌘-click the card)")
        .accessibilityLabel(isSelected ? "Deselect \(voice.name)" : "Select \(voice.name)")
    }
}
