import EncoreCore
import SwiftUI

/// Saved settings for one model: apply one, save the current parameters + post-processing as a new preset,
/// update, rename or delete (stored in `PresetStore`).
///
///     PresetsMenu(manifest: manifest, parameters: $parameters, post: $post)
///
/// The trigger is a neutral pill naming the preset that matches the current settings exactly, if any.
struct PresetsMenu: View {
    let manifest: ModelManifest
    @Binding var parameters: ParamValues
    @Binding var post: PostProcessingOptions

    @Environment(PresetStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @State private var naming: Naming?
    @State private var isHovered = false

    private enum Naming: Identifiable {
        case new
        case rename(Preset)
        var id: String { if case .rename(let p) = self { p.id.uuidString } else { "new" } }
    }

    private var presets: [Preset] { store.presets(for: manifest.id) }

    /// The preset whose settings are exactly the current ones.
    private var matching: Preset? {
        let current = ParameterValues.normalized(parameters, for: manifest)
        return presets.first { ParameterValues.normalized($0.parameters, for: manifest) == current && $0.post == post }
    }

    var body: some View {
        Menu {
            if presets.isEmpty {
                Text("No presets for \(manifest.name) yet")
            } else {
                Section("Apply") {
                    ForEach(presets) { p in
                        Button { apply(p) } label: {
                            if p.id == matching?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                }
            }
            Divider()
            Button("Save current settings as…") { naming = .new }
            if let m = matching {
                Button("Rename “\(m.name)”…") { naming = .rename(m) }
            }
            if !presets.isEmpty {
                Menu("Update with current settings") {
                    ForEach(presets) { p in Button(p.name) { update(p) } }
                }
                Menu("Rename") {
                    ForEach(presets) { p in Button(p.name) { naming = .rename(p) } }
                }
                Menu("Delete") {
                    ForEach(presets) { p in Button(p.name, role: .destructive) { delete(p) } }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: matching != nil ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                Text(matching?.name ?? "Presets")
                    .textRole(.label, color: matching != nil || isHovered ? .textPrimary : .textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.textTertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: Theme.ControlHeight.small)
            .background(Capsule().fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0)))
            .overlay(Capsule().inset(by: 0.5).stroke(isHovered ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Presets for \(manifest.name)")
        .stageSheet(isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            if let naming {
                PresetNameSheet(title: { if case .rename = naming { "Rename preset" } else { "Save preset" } }(),
                                initial: { if case .rename(let p) = naming { p.name } else { "" } }(),
                                modelName: manifest.name) { name in commit(naming, name: name) }
            }
        }
    }

    private func apply(_ p: Preset) {
        withStageAnimation {
            parameters = ParameterValues.normalized(p.parameters, for: manifest)
            post = p.post
        }
        toasts.show("Applied “\(p.name)”", symbol: "bookmark.fill")
    }

    private func update(_ p: Preset) {
        var p = p
        p.parameters = ParameterValues.normalized(parameters, for: manifest)
        p.post = post
        save(p, message: "Updated “\(p.name)”")
    }

    private func delete(_ p: Preset) {
        do {
            try store.delete(p.id)
            toasts.show("Deleted “\(p.name)”", symbol: "trash")
        } catch {
            toasts.show(error.localizedDescription, tone: .danger)
        }
    }

    private func commit(_ naming: Naming, name: String) {
        switch naming {
        case .new:
            save(Preset(name: name, modelID: manifest.id, parameters: ParameterValues.normalized(parameters, for: manifest), post: post),
                 message: "Saved “\(name)”")
        case .rename(var p):
            p.name = name
            save(p, message: "Renamed to “\(name)”")
        }
    }

    private func save(_ p: Preset, message: String) {
        do {
            try store.save(p)
            toasts.show(message, tone: .success, symbol: "bookmark.fill")
        } catch {
            toasts.show(error.localizedDescription, tone: .danger)
        }
    }
}

private struct PresetNameSheet: View {
    let title: String
    let initial: String
    let modelName: String
    let onCommit: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetContainer(title: title, subtitle: "Parameters and post-processing for \(modelName)", width: 400) {
            StageTextField("e.g. Warm narration", text: $name, title: "Name") { if !trimmed.isEmpty { done() } }
        } actions: {
            Button("Cancel") { dismiss() }.buttonStyle(.ghost)
            Button("Save") { done() }.buttonStyle(.primary).disabled(trimmed.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { name = initial }
    }

    private func done() {
        onCommit(trimmed)
        dismiss()
    }
}
