import EncoreCore
import SwiftUI

/// Casts a voice for a model: "automatic" (the model's default), the model's own preset voices, and the user's
/// library (searchable by name and tag). Library voices are only selectable when the model clones; otherwise
/// the panel says why and which downloaded models could use them.
///
///     VoicePicker(manifest: manifest, selection: $voice)
///     VoicePicker(manifest: manifest, selection: $voice, language: languageCode)   // that language's presets first
///
/// - `selection`: `.automatic`, `.preset(id)` or `.library(uuid)`, ready for a request.
struct VoicePicker: View {
    let manifest: ModelManifest
    @Binding var selection: VoiceSelection
    /// Presets in this language are listed first.
    var language: String?
    var panelWidth: CGFloat = 380

    @Environment(AppDependencies.self) private var deps
    @Environment(\.snapshotOpenPicker) private var snapshotOpen
    @State private var isOpen = false

    init(manifest: ModelManifest, selection: Binding<VoiceSelection>, language: String? = nil, panelWidth: CGFloat = 380) {
        self.manifest = manifest
        self._selection = selection
        self.language = language
        self.panelWidth = panelWidth
    }

    var body: some View {
        let d = VoiceDescription(selection, manifest: manifest, library: deps.voices)
        PickerPlate(label: "Voice", symbol: d.symbol, value: d.name, detail: d.detail, isOpen: isOpen, action: { isOpen.toggle() }) {
            if d.isMissing { StatusBadge("Missing", tone: .danger) }
            else if d.isUnusable { StatusBadge("Can't clone", tone: .warning) }
        }
        .pickerPanel(isPresented: $isOpen, width: panelWidth) {
            VoicePickerPanel(manifest: manifest, selection: selection, language: language) { picked in
                selection = picked
                isOpen = false
            } onOpen: { section in
                isOpen = false
                deps.router.go(section)
            }
            .environment(deps)
        }
        .onAppear { if snapshotOpen == "voice" { isOpen = true } }
    }
}

/// How a voice selection reads on its trigger.
struct VoiceDescription {
    var name: String
    var detail: String?
    var symbol: String
    var isMissing = false
    /// A library voice on a model that can't clone.
    var isUnusable = false

    @MainActor init(_ selection: VoiceSelection, manifest: ModelManifest, library: VoiceLibrary) {
        switch selection {
        case .automatic:
            name = "Automatic"
            detail = manifest.presetVoices.isEmpty ? "model default" : "model's default"
            symbol = "sparkles"
        case .preset(let id):
            let p = manifest.presetVoices.first { $0.id == id }
            name = p?.name ?? id
            detail = p.flatMap { Self.presetDetail($0, manifest: manifest) } ?? "model voice"
            symbol = "person.wave.2"
            isMissing = p == nil && !manifest.presetVoices.isEmpty
        case .library(let id):
            let v = library.voices.first { $0.id == id }
            name = v?.name ?? "Deleted voice"
            detail = v.map { $0.origin.label } ?? nil
            symbol = "person.crop.circle.badge.checkmark"
            isMissing = v == nil
            isUnusable = !manifest.capabilities.cloning
        }
    }

    static func presetDetail(_ p: PresetVoice, manifest: ModelManifest) -> String? {
        var parts: [String] = []
        if let g = p.gender { parts.append(g) }
        if let l = p.language, manifest.languages.count > 1 {
            parts.append(manifest.languages.first { $0.code == l }?.name ?? l)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Voice.Origin {
    var label: String {
        switch self {
        case .cloned: "Cloned"
        case .designed: "Designed"
        case .imported: "Imported"
        }
    }
    var symbol: String {
        switch self {
        case .cloned: "mic"
        case .designed: "wand.and.stars"
        case .imported: "square.and.arrow.down"
        }
    }
}

/// The panel inside `VoicePicker`. Usable on its own.
struct VoicePickerPanel: View {
    let manifest: ModelManifest
    var selection: VoiceSelection
    var language: String?
    let onSelect: (VoiceSelection) -> Void
    /// Routes elsewhere (Clone to make a voice, Models for a cloning model).
    let onOpen: (AppSection) -> Void

    @Environment(AppDependencies.self) private var deps
    @State private var query = ""

    private var canClone: Bool { manifest.capabilities.cloning }

    var body: some View {
        let presets = filteredPresets
        let library = deps.voices.search(query)
        VStack(alignment: .leading, spacing: 0) {
            if manifest.presetVoices.count > 8 || deps.voices.voices.count > 5 {
                SearchField(text: $query, prompt: "Search voices and tags")
                    .padding([.horizontal, .top], Theme.Space.m)
                    .padding(.bottom, Theme.Space.xs)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        PickerRow(isSelected: selection == .automatic, action: { onSelect(.automatic) }) {
                            Image(systemName: "sparkles").foregroundStyle(Color.tungsten).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Automatic").textRole(.headline)
                                Text(manifest.presetVoices.isEmpty ? "Whatever voice \(manifest.name) speaks in by default"
                                     : "\(manifest.name)'s default voice").textRole(.caption, color: .textTertiary)
                            }
                        }
                    }
                    if !presets.isEmpty {
                        PanelHeading(title: "Model voices", count: presets.count)
                        ForEach(presets) { p in
                            PickerRow(isSelected: selection == .preset(p.id), action: { onSelect(.preset(p.id)) }) {
                                Image(systemName: "person.wave.2").foregroundStyle(Color.textTertiary).frame(width: 18)
                                Text(p.name).textRole(.body)
                                Spacer(minLength: 4)
                                if let d = VoiceDescription.presetDetail(p, manifest: manifest) {
                                    Text(d).textRole(.caption, color: .textTertiary).lineLimit(1)
                                }
                            }
                        }
                    }
                    libraryHeading(count: library.count)
                    if !canClone {
                        cloneNote.padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(library) { v in
                        PickerRow(isSelected: selection == .library(v.id), isEnabled: canClone, action: { onSelect(.library(v.id)) }) {
                            Image(systemName: v.origin.symbol).foregroundStyle(canClone ? Color.tungsten : Color.textTertiary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(v.name).textRole(.body)
                                    Text(v.origin.label).textRole(.caption, color: .textTertiary)
                                }
                                if !v.tags.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(v.tags.prefix(4), id: \.self) { Chip($0) }
                                    }
                                }
                            }
                            Spacer(minLength: 4)
                            Text(Timecode.seconds(v.duration)).textRole(.monoSmall, color: .textTertiary)
                        }
                    }
                    if deps.voices.voices.isEmpty {
                        HStack {
                            Text("No voices yet. Clone one from a short recording.").textRole(.caption)
                            Spacer()
                            Button("Clone a voice") { onOpen(.clone) }.buttonStyle(.ghost).controlSize(.small)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    } else if library.isEmpty && presets.isEmpty {
                        Text("Nothing matches “\(query)”.").textRole(.caption).padding(10)
                    }
                }
                .padding(Theme.Space.s)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func libraryHeading(count: Int) -> some View {
        PanelHeading(title: "Your voices", count: deps.voices.voices.isEmpty ? nil : count)
    }

    /// Presets matching the search, the chosen language's first.
    private var filteredPresets: [PresetVoice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = manifest.presetVoices.filter { p in
            q.isEmpty || p.name.lowercased().contains(q) || p.id.lowercased().contains(q)
                || (p.gender?.lowercased().contains(q) ?? false)
                || (manifest.languages.first { $0.code == p.language }?.name.lowercased().contains(q) ?? false)
        }
        guard let language else { return all }
        return all.filter { $0.language == language } + all.filter { $0.language != language }
    }

    private var cloneNote: some View {
        let cloners = deps.modelShelf.manifests(for: .tts, requiring: .cloning)
        let ready = cloners.filter(deps.modelShelf.isAnyVariantDownloaded).map(\.name)
        let text = ready.isEmpty
            ? "\(manifest.name) can't clone, so your voices can't be used with it. Download a cloning model (e.g. \(cloners.prefix(2).map(\.name).joined(separator: " or "))) in Models."
            : "\(manifest.name) can't clone, so your voices can't be used with it. Switch to \(ready.prefix(2).joined(separator: " or ")) to cast them."
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Color.footlight)
            Text(text).textRole(.caption).fixedSize(horizontal: false, vertical: true)
            if ready.isEmpty {
                Spacer(minLength: 0)
                Button("Models") { onOpen(.models) }.buttonStyle(.ghost).controlSize(.small)
            }
        }
    }
}

/// Chooses the model's language. Shows nothing when the model has no language list.
///
///     LanguagePicker(manifest: manifest, selection: $language)   // nil = automatic / model default
struct LanguagePicker: View {
    let manifest: ModelManifest
    @Binding var selection: String?

    var body: some View {
        if !manifest.languages.isEmpty {
            let hasAuto = manifest.languages.contains { $0.code.lowercased() == "auto" }
            let options: [String?] = (hasAuto ? [] : [nil]) + manifest.languages.map { Optional($0.code) }
            Menu {
                ForEach(options, id: \.self) { code in
                    Button {
                        selection = code
                    } label: {
                        let title = name(code)
                        if code == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: {
                PickerPlate(label: "Language", symbol: "globe", value: name(selection), isOpen: false, action: {})
                    .allowsHitTesting(false)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Language: \(name(selection))")
        }
    }

    private func name(_ code: String?) -> String {
        guard let code else { return "Automatic" }
        return manifest.languages.first { $0.code == code }?.name ?? code
    }
}
