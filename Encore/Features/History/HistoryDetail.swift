import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// The selected item in full: its title (renamable), the player, the script or the timed transcript, everything it
/// was made with, timings, and its actions.
struct HistoryDetail: View {
    @Bindable var model: HistoryModel
    let item: HistoryItem
    /// The one-line player, for the narrow drawer.
    var compactPlayer = false
    @Environment(ToastCenter.self) private var toasts
    @State private var draftTitle: String?

    private var manifest: ModelManifest? {
        let id = item.generation?.modelID ?? item.transcription?.modelID
        return id.flatMap { model.service.catalog.model($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Theme.Space.m)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    actions
                    switch item.record {
                    case .generation(let g): generation(g)
                    case .transcription(let t): transcription(t)
                    }
                }
                .padding(.bottom, Theme.Space.l)
                .padding(.trailing, Theme.Space.xs)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.leading, Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .overlay(alignment: .leading) {
            if !compactPlayer { edge }
        }
        .onChange(of: item.id) { _, _ in draftTitle = nil }
    }

    /// The hairline between list and detail, lit faintly at its middle.
    private var edge: some View {
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.hairlineStrong, Color.tungsten.opacity(0.18), Color.hairlineStrong, .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
    }

    // MARK: Header

    private var header: some View {
        let style = HistoryKindStyle(item.kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: style.symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(style.color)
                Text(style.name).textRole(.eyebrow, color: style.color.opacity(0.85))
                Text("· \(item.createdAt.formatted(date: .abbreviated, time: .shortened))").textRole(.eyebrow)
                Spacer(minLength: 4)
                Button("Close details", systemImage: "xmark") { model.focusedID = nil }
                    .buttonStyle(.icon).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            if let draft = draftTitle {
                StageTextField("Title", text: Binding(get: { draft }, set: { draftTitle = $0 }), onSubmit: commitRename)
                    .onExitCommand { draftTitle = nil }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(item.title).textRole(.heading).lineLimit(3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Rename", systemImage: "pencil") { draftTitle = item.title }
                        .buttonStyle(.icon).controlSize(.small)
                        .help("Rename")
                }
            }
        }
    }

    private func commitRename() {
        guard let draft = draftTitle else { return }
        draftTitle = nil
        Task {
            do { try await model.rename(item, to: draft) } catch { toasts.show(error.localizedDescription, tone: .danger) }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: Theme.Space.xs) {
            if model.canReuse(item) {
                Button("Reuse in Studio", systemImage: "arrow.uturn.backward") {
                    if let problem = model.reuseInStudio(item) { toasts.show(problem, tone: .warning) }
                    else { toasts.show("Loaded the take's settings into the Studio", symbol: "arrow.uturn.backward") }
                }
                .buttonStyle(.secondary).controlSize(.small)
                .help("Model, variant, voice, language, direction, parameters, finishing and script")
            }
            if model.canOpenInTranscribe(item) {
                Button("Open in Transcribe", systemImage: "captions.bubble") { model.openInTranscribe(item) }
                    .buttonStyle(.secondary).controlSize(.small)
                    .help("The transcript with its player, timings and exports")
            }
            Spacer(minLength: 0)
            Button(item.favorite ? "Unfavorite" : "Favorite", systemImage: item.favorite ? "star.fill" : "star") { model.toggleFavorite(item) }
                .buttonStyle(.icon(tone: item.favorite ? .accent : .neutral)).controlSize(.small)
                .help(item.favorite ? "Remove from favorites" : "Favorite")
            Button(item.kind == .transcription ? "Copy transcript" : "Copy script", systemImage: "doc.on.doc") {
                model.copyText(item)
                toasts.show("Copied", symbol: "doc.on.doc")
            }
            .buttonStyle(.icon).controlSize(.small)
            .help(item.kind == .transcription ? "Copy the transcript" : "Copy the script")
            Button("Show in Finder", systemImage: "folder") { model.reveal(item) }
                .buttonStyle(.icon).controlSize(.small)
                .help(item.kind == .transcription ? "Show the source file in Finder" : "Show the audio file in Finder")
            if let t = item.transcription { TranscriptExportMenu(record: t, title: item.title) }
            Button("Delete…", systemImage: "trash") { model.requestDelete([item.id]) }
                .buttonStyle(.icon(tone: .danger)).controlSize(.small)
                .help("Delete for good")
        }
    }

    // MARK: Generation

    @ViewBuilder private func generation(_ g: GenerationRecord) -> some View {
        WaveformPlayer(url: g.audioURL, title: item.title, subtitle: [g.voiceName, g.modelName].compactMap { $0 }.joined(separator: " · "),
                       style: compactPlayer ? .compact : .regular)
        switch g.kind {
        case .voiceChange:
            DetailSection("Source") { Text(g.text).textRole(.body).textSelection(.enabled) }
        default:
            DetailSection(g.kind == .conversation ? "Script" : (g.kind == .voiceDesign ? "Sample line" : "Script")) {
                Text(HistoryHighlight.attributed(g.text, terms: model.searchTerms))
                    .font(.ui(13)).lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .surface(.sunken, radius: Theme.Radius.m)
            }
        }
        DetailSection("Made with") {
            info("Model", g.modelName)
            if let v = variantLabel(g.variantID) { info("Variant", v) }
            if let r = g.runtime { info("Runtime", r == .mlxSwift ? "Native (MLX Swift)" : "Python helper (mlx-audio)") }
            if let v = g.voiceName, !v.isEmpty { info(g.kind == .conversation ? "Voices" : "Voice", v) }
            if let l = g.language { info("Language", languageName(l)) }
            if let i = g.instruct {
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.kind == .voiceDesign || manifest?.capabilities.styleInstruction != true ? "Description" : "Direction")
                        .textRole(.body, color: .textSecondary)
                    Text("“\(i)”").textRole(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
            }
        }
        parameters(g.parameters)
        if let p = g.post { finishing(p) }
        DetailSection("Timings") {
            info("Created", g.createdAt.formatted(date: .abbreviated, time: .shortened))
            info("Audio", Timecode.string(g.duration), mono: true)
            if g.elapsed > 0 {
                info("Took", RunSurface.seconds(g.elapsed), mono: true)
                if g.duration > 0 { info("Speed", String(format: "%.1f× real time", g.duration / g.elapsed), mono: true) }
            }
            info("Sample rate", String(format: "%g kHz", g.sampleRate / 1000), mono: true)
        }
    }

    @ViewBuilder private func parameters(_ values: ParamValues) -> some View {
        if !values.isEmpty {
            DetailSection("Parameters") {
                let specs = manifest?.parameters ?? []
                let known = specs.filter { values[$0.key] != nil }
                let unknown = values.keys.filter { k in !specs.contains { $0.key == k } }.sorted()
                ForEach(known) { spec in
                    let v = values[spec.key]!
                    let changed = spec.defaultValue.map { $0 != v } ?? true
                    KeyValueRow(spec.label) {
                        HStack(spacing: 5) {
                            if changed { Circle().fill(Color.tungsten).frame(width: 4, height: 4).help("Changed from the default") }
                            Text(format(v, spec)).textRole(.mono, color: changed ? .tungsten : .textPrimary).textSelection(.enabled)
                        }
                    }
                }
                ForEach(unknown, id: \.self) { k in info(k, format(values[k]!, nil), mono: true) }
            }
        }
    }

    private func finishing(_ p: PostProcessingOptions) -> some View {
        DetailSection("Finishing") {
            info("Loudness", p.normalizeLoudness ? String(format: "%g LUFS", p.targetLUFS) : "As generated")
            info("Silences", p.removeSilence ? String(format: "Trimmed, gaps ≤ %g s", p.maxSilenceSeconds) : "Kept")
        }
    }

    // MARK: Transcription

    @ViewBuilder private func transcription(_ t: TranscriptionRecord) -> some View {
        let source = URL(fileURLWithPath: t.sourcePath)
        if FileManager.default.fileExists(atPath: source.path), AudioFileFormat(fileExtension: source.pathExtension) != nil {
            WaveformPlayer(url: source, title: t.sourceName, subtitle: "Source", style: compactPlayer ? .compact : .regular)
        }
        DetailSection("Transcript") {
            let segments = t.transcript.segments
            if segments.isEmpty {
                Text(HistoryHighlight.attributed(t.transcript.text, terms: model.searchTerms)).font(.ui(13)).lineSpacing(3).textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(segments) { s in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text(Timecode.string(s.start, tenths: false)).textRole(.monoSmall, color: .tungsten.opacity(0.8))
                                .frame(width: 40, alignment: .leading)
                            Text(HistoryHighlight.attributed(s.text.trimmingCharacters(in: .whitespaces), terms: model.searchTerms))
                                .font(.ui(12.5)).lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(Theme.Space.m)
                .surface(.sunken, radius: Theme.Radius.m)
            }
        }
        DetailSection("Made with") {
            info("Model", t.modelName)
            if let v = variantLabel(t.variantID) { info("Variant", v) }
            if let r = t.runtime { info("Runtime", r == .mlxSwift ? "Native (MLX Swift)" : "Python helper (mlx-audio)") }
            info("Language", t.language.map(languageName) ?? (t.transcript.language.map { "\(languageName($0)) (detected)" } ?? "Automatic"))
            if let ts = t.timestamps { info("Timestamps", ts == .word ? "Words" : (ts == .segment ? "Segments" : "None")) }
            info("Source", t.sourceName)
        }
        if let p = t.parameters { parameters(p) }
        DetailSection("Timings") {
            info("Created", t.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let d = t.transcript.duration { info("Audio", Timecode.string(d), mono: true) }
            if t.elapsed > 0 {
                info("Took", RunSurface.seconds(t.elapsed), mono: true)
                if let d = t.transcript.duration, d > 0 { info("Speed", String(format: "%.0f× real time", d / t.elapsed), mono: true) }
            }
            info("Segments", "\(t.transcript.segments.count)", mono: true)
        }
    }

    // MARK: Formatting

    /// A label and its value; names wrap on the right, numbers are monospaced.
    private func info(_ key: String, _ value: String, mono: Bool = false) -> some View {
        KeyValueRow(key) {
            Text(value)
                .textRole(mono ? .mono : .label, color: .textPrimary)
                .layoutPriority(1)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func variantLabel(_ id: String?) -> String? {
        guard let id else { return nil }
        return manifest?.variants.first { $0.id == id }?.label ?? id
    }

    private func languageName(_ code: String) -> String {
        manifest?.languages.first { $0.code == code }?.name ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func format(_ v: ParamValue, _ spec: ParameterSpec?) -> String {
        if let options = spec?.options, let s = v.stringValue, let o = options.first(where: { $0.value == s }) { return o.label }
        let unit = spec?.unit.map { " \($0)" } ?? ""
        switch v {
        case .bool(let b): return b ? "On" : "Off"
        case .int(let i): return "\(i)\(unit)"
        case .double(let d): return String(format: "%g", d) + unit
        case .string(let s): return s
        }
    }
}

/// A titled group in the detail panel.
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: 6) {
                Text(title).textRole(.eyebrow)
                Rectangle().fill(Color.hairline).frame(height: 1)
            }
            .padding(.bottom, 2)
            content
        }
    }
}

/// Saves a transcript as text, timed text, subtitles or JSON.
private struct TranscriptExportMenu: View {
    let record: TranscriptionRecord
    let title: String
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        Menu {
            Section("Export transcript") {
                ForEach(TranscriptFormat.allCases) { f in Button("\(f.label)…") { export(f) } }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: Theme.ControlHeight.small * 0.4, weight: .semibold))
                .foregroundStyle(Color.textPrimary.opacity(0.7))
                .frame(width: Theme.ControlHeight.small, height: Theme.ControlHeight.small)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Export the transcript")
        .accessibilityLabel("Export transcript")
    }

    private func export(_ format: TranscriptFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(AudioExportActions.sanitized((title as NSString).deletingPathExtension)).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        let transcript = record.transcript
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try TranscriptFormatter().data(transcript, as: format).write(to: url, options: .atomic)
                toasts.show("Saved “\(url.lastPathComponent)”", tone: .success)
            } catch {
                toasts.show(error.localizedDescription, tone: .danger, duration: 6)
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}
