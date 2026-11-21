import EncoreCore
import SwiftUI

/// One voice as a playbill card: origin and language eyebrow, the name in the display face, tags, the reference
/// clip on a compact player, and its facts along a perforated stub. Lit tungsten when open in the inspector.
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
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: voice.origin.symbol).font(.system(size: 9, weight: .bold))
                    Text(eyebrow).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.ui(10, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(originColor.opacity(0.9))
                .padding(.trailing, 26)
                Text(voice.name)
                    .font(.display(22))
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !voice.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(voice.tags.prefix(4), id: \.self) { Chip($0) }
                        if voice.tags.count > 4 { Text("+\(voice.tags.count - 4)").textRole(.monoSmall, color: .textTertiary) }
                    }
                    .lineLimit(1)
                } else if let line = blurb {
                    Text(line).font(.display(13, italic: true)).foregroundStyle(.textTertiary).lineLimit(1)
                        .frame(height: 22, alignment: .leading)
                } else {
                    Color.clear.frame(height: 22)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)

            Group {
                if let reference {
                    WaveformPlayer(url: reference, title: "Reference", subtitle: nil, style: .compact)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.velvet)
                        Text("Reference clip missing").textRole(.caption)
                    }
                    .frame(height: 38)
                }
            }
            .padding(.horizontal, Theme.Space.m)

            PerforatedDivider(bleed: 0)
                .padding(.top, Theme.Space.s)
            HStack(spacing: Theme.Space.s) {
                Text(String(format: "%.1f s", voice.duration))
                if let l = voice.language { dot; Text(VoiceLanguages.name(l)) }
                Spacer(minLength: Theme.Space.xs)
                Text(voice.createdAt.formatted(.dateTime.day().month(.abbreviated).year()))
            }
            .font(.mono(10.5))
            .foregroundStyle(.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 9)
        }
        .background {
            shape.fill(Color.surface)
                .overlay(shape.fill(LinearGradient(colors: [originColor.opacity(isFocused ? 0.1 : 0.05), .clear],
                                                   startPoint: .topLeading, endPoint: .center)))
        }
        .overlay {
            shape.strokeBorder(isFocused || isSelected ? Color.tungsten.opacity(isFocused ? 0.85 : 0.55)
                               : (isHovered ? Color.hairlineStrong : Color.hairline), lineWidth: isFocused ? 1.5 : 1)
        }
        .overlay(alignment: .topTrailing) { check.padding(Theme.Space.m - 5) }
        .glow(.tungsten, radius: 14, intensity: isFocused ? 0.18 : 0)
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

    private var dot: some View { Text("·") }

    private var eyebrow: String { voice.origin.label }

    private var blurb: String? {
        if let p = voice.designPrompt, !p.isEmpty { return p }
        return voice.transcript.isEmpty ? nil : "“\(voice.transcript)”"
    }

    private var originColor: Color {
        switch voice.origin {
        case .cloned: .tungsten
        case .designed: .mint
        case .imported: .textSecondary
        }
    }

    /// A round tick for multi-select: shown on hover, and always while voices are being picked. Clicking it
    /// checks this card (starting a multi-selection) or unchecks it.
    private var check: some View {
        Button(action: onToggle) {
            ZStack {
                Circle().fill(isSelected ? Color.tungsten : Color.surfaceSunken.opacity(0.9))
                Circle().strokeBorder(isSelected ? Color.tungsten : Color.textTertiary.opacity(0.7), lineWidth: 1.2)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Color.onTungsten)
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
