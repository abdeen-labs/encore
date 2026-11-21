import EncoreCore
import SwiftUI

/// One take: the waveform player (play, scrub, export, drag out) with the take's star and actions,
/// and a lit edge for takes made in this session.
struct TakeCard: View {
    let item: HistoryItem
    let record: GenerationRecord
    var isNew: Bool
    var onFavorite: () -> Void
    var onReuse: () -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        WaveformPlayer(url: record.audioURL, title: item.title, subtitle: subtitle)
            .accessory {
                Button(item.favorite ? "Unfavorite" : "Favorite", systemImage: item.favorite ? "star.fill" : "star", action: onFavorite)
                    .buttonStyle(.icon(tone: item.favorite ? .accent : .neutral))
                    .controlSize(.small)
                    .help(item.favorite ? "Remove from favorites" : "Favorite")
                Menu {
                    Button("Reuse these settings", systemImage: "arrow.uturn.backward", action: onReuse)
                    Button("Copy script", systemImage: "doc.on.doc", action: onCopy)
                    Divider()
                    Button("Delete take…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textPrimary.opacity(0.7))
                        .frame(width: Theme.ControlHeight.small, height: Theme.ControlHeight.small)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, -4)
                .help("More")
                .accessibilityLabel("More actions")
            }
            .overlay(alignment: .topLeading) {
                if isNew {
                    Text("New")
                        .font(.ui(9, weight: .bold)).tracking(1.2).textCase(.uppercase)
                        .foregroundStyle(Color.onTungsten)
                        .padding(.horizontal, 6).frame(height: 15)
                        .background(Capsule().fill(Color.tungsten))
                        .glow(.tungsten, radius: 5, intensity: 0.35)
                        .offset(x: 12, y: -7)
                }
            }
            .overlay {
                if isNew {
                    RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                        .strokeBorder(Color.tungsten.opacity(0.35), lineWidth: 1)
                }
            }
            .help(record.text)
            .confirmationDialog("Delete “\(item.title)”?", isPresented: $confirmingDelete) {
                Button("Delete take", role: .destructive, action: onDelete)
            } message: {
                Text("It's removed from history, and its audio file goes to the Trash.")
            }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = record.voiceName { parts.append(v) }
        parts.append(record.modelName)
        if record.elapsed > 0 { parts.append("made in \(RunSurface.seconds(record.elapsed))") }
        return parts.joined(separator: " · ")
    }
}
