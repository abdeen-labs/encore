import AppKit
import EncoreCore
import SwiftUI

/// One take in the Studio's list: play, the title, the voice and length, a star, and a "…" menu with the rest
/// (reuse settings, copy script, export, show in Finder, delete). The take in the player dock and the newest take
/// of this session open up to show their waveform; the others stay one compact row.
struct TakeRow: View {
    let item: HistoryItem
    let record: GenerationRecord
    /// The newest take made in this session.
    var isNewest: Bool
    var onFavorite: () -> Void
    var onReuse: () -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State private var track: PlaybackTrack
    @State private var scrubTime: TimeInterval?
    @State private var confirmingDelete = false
    @State private var ffmpegAvailable = true
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @Environment(ExportProgressCenter.self) private var exports: ExportProgressCenter?

    init(item: HistoryItem, record: GenerationRecord, isNewest: Bool, onFavorite: @escaping () -> Void,
         onReuse: @escaping () -> Void, onCopy: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.record = record
        self.isNewest = isNewest
        self.onFavorite = onFavorite
        self.onReuse = onReuse
        self.onCopy = onCopy
        self.onDelete = onDelete
        _track = State(initialValue: PlaybackTrack(url: record.audioURL, title: item.title, subtitle: record.voiceName))
    }

    /// This take is the one in the player dock (playing or paused).
    private var isCurrent: Bool {
        guard let mine = track.player, let current = NowPlaying.shared.player else { return false }
        return mine === current
    }

    var body: some View {
        let isOpen = isNewest || isCurrent
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Button(track.isPlaying ? "Pause" : "Play", systemImage: track.isPlaying ? "pause.fill" : "play.fill") { track.toggle() }
                    .buttonStyle(.play(isPlaying: track.isPlaying))
                    .controlSize(.small)
                    .help(track.isPlaying ? "Pause" : "Play")
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).textRole(.headline).lineLimit(1).truncationMode(.tail)
                    Text(caption).textRole(.caption).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrag { AudioExportActions.dragProvider(for: track.source, suggestedName: track.title) }
                .help(details)
                Button(item.favorite ? "Unfavorite" : "Favorite", systemImage: item.favorite ? "star.fill" : "star", action: onFavorite)
                    .buttonStyle(.icon)
                    .controlSize(.small)
                    .help(item.favorite ? "Remove from favorites" : "Favorite")
                menu
            }
            if isOpen {
                TrackWaveform(track: track, height: 26, barWidth: 2, gap: 1.25, scrubTime: $scrubTime)
                    .padding(.leading, Theme.ControlHeight.small + Theme.Space.m)
                    .task { await track.loadPeaks() }
                    .transition(.opacity)
            }
            if let message = track.loadError {
                Text(message).textRole(.caption, color: .velvetText).lineLimit(1)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .stageAnimation(Theme.Motion.standard, value: isOpen)
        .onChange(of: item.title) { _, t in track.title = t }
        .task { ffmpegAvailable = FFmpeg.isAvailable }
        .confirmationDialog("Delete “\(item.title)”?", isPresented: $confirmingDelete) {
            Button("Delete take", role: .destructive, action: onDelete)
        } message: {
            Text("It's removed from history, and its audio file goes to the Trash.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }

    /// The voice and the length.
    private var caption: String {
        let length = Timecode.string(record.duration, tenths: false)
        return [record.voiceName ?? record.modelName, length].joined(separator: " · ")
    }

    /// The script, then what made it, for the tooltip.
    private var details: String {
        var made = record.modelName
        if record.elapsed > 0 { made += ", made in \(RunSurface.seconds(record.elapsed))" }
        return "\(record.text)\n\n\(made)"
    }

    private var menu: some View {
        Menu {
            Button("Reuse these settings", systemImage: "arrow.uturn.backward", action: onReuse)
            Button("Copy script", systemImage: "doc.on.doc", action: onCopy)
            Divider()
            Section("Export") {
                Button("WAV (lossless)…") { export(.wav) }
                Button("M4A (AAC)…") { export(.m4a) }
                if ffmpegAvailable {
                    Button("MP3…") { export(.mp3) }
                } else {
                    Button("MP3 needs ffmpeg — copy “brew install ffmpeg”") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                        toasts?.show("Copied. Run it in Terminal, or set ffmpeg's location in Settings.", tone: .neutral, duration: 5)
                    }
                }
            }
            Button("Show in Finder", systemImage: "folder") { AudioExportActions.revealInFinder(record.audioURL) }
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
        .help("More")
        .accessibilityLabel("More actions")
    }

    private func export(_ format: AudioFileFormat) {
        AudioExportActions.export(track.source, format: format, suggestedName: item.title, toasts: toasts, exports: exports)
    }
}
