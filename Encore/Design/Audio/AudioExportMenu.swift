import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// What a piece of audio on screen is backed by.
enum AudioSource {
    case file(URL)
    case buffer(AudioBuffer)
    /// Peaks only (previews, the gallery). Can't be played or exported.
    case preview(WaveformPeaks)

    var fileURL: URL? { if case .file(let u) = self { u } else { nil } }
    var canPlay: Bool { if case .preview = self { false } else { true } }
}

/// Exports and drag-out for an `AudioSource`.
@MainActor enum AudioExportActions {
    /// Shows a save panel, then writes the audio in `format`. Reports the result through `toasts` when given.
    static func export(_ source: AudioSource, format: AudioFileFormat, suggestedName: String, toasts: ToastCenter?) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [contentType(for: format)]
        panel.nameFieldStringValue = "\(sanitized(suggestedName)).\(format.fileExtension)"
        panel.title = "Export \(format.displayName)"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                toasts?.show("Exporting \(destination.lastPathComponent)…", symbol: "square.and.arrow.up", duration: 30)
                do {
                    switch source {
                    case .file(let url): try await AudioExporter.convert(url, to: destination, format: format)
                    case .buffer(let buffer): try await AudioExporter.export(buffer, to: destination, format: format)
                    case .preview: throw AudioError.invalidArgument("Nothing to export.")
                    }
                    toasts?.show("Saved “\(destination.lastPathComponent)”", tone: .success)
                } catch {
                    toasts?.show(error.localizedDescription, tone: .danger, duration: 6)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// An item provider for dragging the audio out to Finder or another app. Buffers are written to a
    /// temporary WAV first.
    static func dragProvider(for source: AudioSource, suggestedName: String) -> NSItemProvider {
        switch source {
        case .file(let url):
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        case .buffer(let buffer):
            let url = EncorePaths.scratch.appendingPathComponent("\(sanitized(suggestedName)).wav")
            do {
                try AudioExporter.writeWAV(buffer, to: url)
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            } catch {
                return NSItemProvider()
            }
        case .preview:
            return NSItemProvider()
        }
    }

    static func contentType(for format: AudioFileFormat) -> UTType {
        switch format {
        case .wav: .wav
        case .m4a: .mpeg4Audio
        case .mp3: .mp3
        }
    }

    static func sanitized(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Encore audio" : String(cleaned.prefix(80))
    }
}

/// The ⋯/share menu on audio cards: export as WAV / M4A / MP3, reveal in Finder.
/// When ffmpeg is missing the MP3 entry explains how to get it instead of failing later.
struct AudioExportMenu: View {
    let source: AudioSource
    let suggestedName: String
    var symbol: String = "square.and.arrow.up"

    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @Environment(\.controlSize) private var controlSize
    @State private var ffmpegAvailable = true
    @State private var isHovered = false

    var body: some View {
        let size = Theme.ControlHeight.of(controlSize)
        Menu {
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
            if let url = source.fileURL {
                Divider()
                Button("Show in Finder") { AudioExportActions.revealInFinder(url) }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(isHovered ? Color.textPrimary : Color.textPrimary.opacity(0.7))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.textPrimary.opacity(isHovered ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!source.canPlay)
        .onHover { isHovered = $0 }
        .help("Export or reveal")
        .accessibilityLabel("Export")
        .task { ffmpegAvailable = FFmpeg.isAvailable }
    }

    private func export(_ format: AudioFileFormat) {
        AudioExportActions.export(source, format: format, suggestedName: suggestedName, toasts: toasts)
    }
}
