import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// The selected item in full: what it is and when, its title (renamable), one player, its actions, then the script
/// or the timed transcript, what it was made with, and at the bottom the settings and timings in plain words.
struct HistoryDetail: View {
    @Bindable var model: HistoryModel
    let item: HistoryItem
    /// Drawn as a drawer over the list (narrow windows), which brings its own card, so no edge hairline.
    var floating = false
    @Environment(ToastCenter.self) private var toasts
    @State private var draftTitle: String?

    private var manifest: ModelManifest? {
        let id = item.generation?.modelID ?? item.transcription?.modelID
        return id.flatMap { model.service.catalog.model($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                player
                actions
            }
            .padding(.bottom, Theme.Space.l)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
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
            if !floating { Hairline(.vertical) }
        }
        .onChange(of: item.id) { _, _ in draftTitle = nil }
    }

    // MARK: Header

    /// The kind and date on one caption line, then the title once.
    private var header: some View {
        let style = HistoryKindStyle(item.kind)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: 6) {
                KindMark(kind: item.kind, size: 14)
                Text("\(style.name) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .textRole(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Close details", systemImage: "xmark") { model.focusedID = nil }
                    .buttonStyle(.icon).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
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

    // MARK: Player

    /// One compact player: it shows no title, so nothing above is repeated. The title still names exports and drags.
    @ViewBuilder private var player: some View {
        switch item.record {
        case .generation(let g):
            WaveformPlayer(url: g.audioURL, title: item.title,
                           subtitle: [g.voiceName, g.modelName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                           style: .compact)
        case .transcription(let t):
            let source = URL(fileURLWithPath: t.sourcePath)
            if FileManager.default.fileExists(atPath: source.path), AudioFileFormat(fileExtension: source.pathExtension) != nil {
                WaveformPlayer(url: source, title: t.sourceName, subtitle: "Source", style: .compact)
            }
        }
    }

    // MARK: Actions

    /// One secondary action where it applies, then quiet icons.
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
                .buttonStyle(.icon).controlSize(.small)
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
                .help("Delete")
        }
    }

    // MARK: Generation

    @ViewBuilder private func generation(_ g: GenerationRecord) -> some View {
        if g.kind != .voiceChange {
            DetailSection(g.kind == .voiceDesign ? "Sample line" : "Script") {
                Text(HistoryHighlight.attributed(g.text, terms: model.searchTerms))
                    .textRole(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        DetailSection("Made with") {
            info("Model", g.modelName)
            if manifest == nil {
                notInCatalog(g.kind == .speech ? "The take still plays and exports; it can't be reused in the Studio." : nil)
            }
            variantRow(g.variantID)
            if let v = g.voiceName, !v.isEmpty { info(g.kind == .conversation ? "Voices" : "Voice", v) }
            if g.kind == .voiceChange { info("Source", g.text) }
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
        settings(g.parameters, post: g.post)
        DetailSection("Details") {
            info("Length", Timecode.string(g.duration), mono: true)
            if g.elapsed > 0 {
                info("Took", RunSurface.seconds(g.elapsed), mono: true)
                if g.duration > 0 { info("Speed", String(format: "%.1f× real time", g.duration / g.elapsed)) }
            }
            info("Sample rate", String(format: "%g kHz", g.sampleRate / 1000), mono: true)
            if let r = g.runtime { info("Ran on", r.displayName) }
        }
    }

    /// Parameters and finishing, together: changed values in full text, defaults quieter.
    @ViewBuilder private func settings(_ values: ParamValues, post: PostProcessingOptions?) -> some View {
        if !values.isEmpty || post != nil {
            DetailSection("Settings") {
                let specs = manifest?.parameters ?? []
                let known = specs.filter { values[$0.key] != nil }
                let unknown = values.keys.filter { k in !specs.contains { $0.key == k } }.sorted()
                ForEach(known) { spec in
                    let v = values[spec.key]!
                    let changed = spec.defaultValue.map { $0 != v } ?? true
                    KeyValueRow(spec.label) {
                        Text(format(v, spec))
                            .textRole(isNumber(v, spec) ? .mono : .label, color: changed ? .textPrimary : .textSecondary)
                            .textSelection(.enabled)
                    }
                    .help(changed ? "Changed from the default" : "The default")
                }
                ForEach(unknown, id: \.self) { k in info(k, format(values[k]!, nil), mono: isNumber(values[k]!, nil)) }
                if let p = post {
                    info("Loudness", p.normalizeLoudness ? String(format: "Evened to %g LUFS", p.targetLUFS) : "As generated")
                    info("Silences", p.removeSilence ? String(format: "Trimmed to %g s at most", p.maxSilenceSeconds) : "Kept")
                }
            }
        }
    }

    // MARK: Transcription

    @ViewBuilder private func transcription(_ t: TranscriptionRecord) -> some View {
        DetailSection("Transcript") {
            let segments = t.transcript.segments
            if segments.isEmpty {
                Text(HistoryHighlight.attributed(t.transcript.text, terms: model.searchTerms))
                    .textRole(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(segments) { s in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text(Timecode.string(s.start, tenths: false)).textRole(.monoSmall, color: .textTertiary)
                                .frame(width: 40, alignment: .leading)
                            Text(HistoryHighlight.attributed(s.text.trimmingCharacters(in: .whitespaces), terms: model.searchTerms))
                                .textRole(.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        DetailSection("Made with") {
            info("Model", t.modelName)
            if manifest == nil { notInCatalog(nil) }
            variantRow(t.variantID)
            info("Language", t.language.map(languageName) ?? (t.transcript.language.map { "\(languageName($0)) (detected)" } ?? "Automatic"))
            if let ts = t.timestamps { info("Timestamps", ts == .word ? "Words" : (ts == .segment ? "Segments" : "None")) }
            info("Source", t.sourceName)
        }
        if let p = t.parameters { settings(p, post: nil) }
        DetailSection("Details") {
            if let d = t.transcript.duration { info("Length", Timecode.string(d), mono: true) }
            if t.elapsed > 0 {
                info("Took", RunSurface.seconds(t.elapsed), mono: true)
                if let d = t.transcript.duration, d > 0 { info("Speed", String(format: "%.0f× real time", d / t.elapsed)) }
            }
            info("Segments", "\(t.transcript.segments.count)", mono: true)
            if let r = t.runtime { info("Ran on", r.displayName) }
        }
    }

    /// The record names a model this version of Encore no longer ships (one dropped from the catalog).
    private func notInCatalog(_ detail: String?) -> some View {
        Label {
            Text(["This model is no longer in Encore's catalog.", detail].compactMap { $0 }.joined(separator: " "))
                .textRole(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "archivebox").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, 3)
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

    /// The variant in plain words ("Balanced") while the model is in the catalog, with its catalog label in the
    /// tooltip; otherwise the stored label.
    @ViewBuilder private func variantRow(_ id: String?) -> some View {
        if let id {
            if let manifest, let variant = manifest.variants.first(where: { $0.id == id }) {
                info("Variant", variant.friendlyName(in: manifest))
                    .help(variant.label)
            } else {
                info("Variant", id)
            }
        }
    }

    private func languageName(_ code: String) -> String {
        manifest?.languages.first { $0.code == code }?.name ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Whether `v` shows as a number (monospaced) rather than a word.
    private func isNumber(_ v: ParamValue, _ spec: ParameterSpec?) -> Bool {
        if let options = spec?.options, let s = v.stringValue, options.contains(where: { $0.value == s }) { return false }
        switch v {
        case .int, .double: return true
        case .bool, .string: return false
        }
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
            Text(title).textRole(.section)
                .padding(.bottom, Theme.Space.xxs)
                .accessibilityAddTraits(.isHeader)
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
