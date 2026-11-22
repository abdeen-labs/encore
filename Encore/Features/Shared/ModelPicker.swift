import EncoreCore
import SwiftUI

/// Chooses a model and variant for a task. The plate shows the model's name, with a warning glyph only when the
/// choice needs action (not downloaded, or can't run here). The panel lists every model that can do the job,
/// downloaded ones first: name, a one-line summary, and on the right either "On this Mac" or the download size.
/// A row speaks up only when something needs attention: a non-commercial license, a tight or impossible memory
/// fit, a runtime that can't run here. Engineering detail (precision, runtime, RAM) stays in tooltips.
///
///     ModelPicker(task: .tts, selection: $choice)
///     ModelPicker(task: .tts, requires: .cloning, feature: .cloning, selection: $choice)
///
/// - `selection`: the chosen model; `variantID` nil means the recommended variant.
/// - `requires`: only models with these capabilities are listed (and the runtime check includes them).
/// - `feature`: when set, a pick is remembered in `AppSettings.lastUsedModels` for that feature, so
///   `ModelShelf.initialChoice(for:requiring:feature:settings:)` starts there next time.
struct ModelPicker: View {
    let task: ModelTask
    var requires: ModelRequirement = []
    var feature: AppSettings.Feature?
    @Binding var selection: ModelChoice?
    /// Width of the open panel.
    var panelWidth: CGFloat = 430

    @Environment(AppDependencies.self) private var deps
    @Environment(\.snapshotOpenPicker) private var snapshotOpen
    @State private var isOpen = false

    init(task: ModelTask, requires: ModelRequirement = [], feature: AppSettings.Feature? = nil,
         selection: Binding<ModelChoice?>, panelWidth: CGFloat = 430) {
        self.task = task
        self.requires = requires
        self.feature = feature
        self._selection = selection
        self.panelWidth = panelWidth
    }

    /// Non-optional binding convenience.
    init(task: ModelTask, requires: ModelRequirement = [], feature: AppSettings.Feature? = nil,
         selection: Binding<ModelChoice>, panelWidth: CGFloat = 430) {
        self.init(task: task, requires: requires, feature: feature,
                  selection: Binding<ModelChoice?>(get: { selection.wrappedValue }, set: { if let v = $0 { selection.wrappedValue = v } }),
                  panelWidth: panelWidth)
    }

    private var shelf: ModelShelf { deps.modelShelf }
    private var manifest: ModelManifest? { selection.flatMap { deps.catalog.model($0.modelID) } }

    var body: some View {
        let m = manifest
        PickerPlate(label: "Model", symbol: "cpu", value: m?.name ?? "Choose a model",
                    isOpen: isOpen, action: { isOpen.toggle() }) {
            if let m, shelf.hasScanned, !shelf.isDownloaded(m, variantID: selection?.variantID) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tone.warning.textColor)
                    .help("Not downloaded yet")
                    .accessibilityLabel("Not downloaded")
            } else if let m {
                RuntimeMark(verdict: shelf.runtime(for: m, requiring: requires) ?? shelf.runtime(for: m))
            }
        }
        .pickerPanel(isPresented: $isOpen, width: panelWidth) {
            ModelPickerPanel(task: task, requires: requires, selection: selection) { choice in
                selection = choice
                if let feature { deps.settings.noteModelUsed(choice.modelID, for: feature) }
                isOpen = false
            } onOpenModels: {
                isOpen = false
                deps.router.go(.models)
            }
            .environment(deps)
        }
        .onAppear { if snapshotOpen == "model" { isOpen = true } }
        .task(id: requires.rawValue) {
            // Cheap: the runtime is planned without starting any backend.
            if !requires.isEmpty { await shelf.refreshRuntimes(for: shelf.manifests(for: task, requiring: requires), requiring: requires) }
        }
    }
}

/// A warning glyph for a model that can't run here (the tooltip says why); nothing when it can. Which runtime a
/// model uses is an engineering detail and isn't shown.
struct RuntimeMark: View {
    let verdict: RuntimeVerdict?

    var body: some View {
        if case .blocked(let e)? = verdict {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tone.warning.textColor)
                .help(e.errorDescription ?? ModelPickerPanel.blockedLabel(e))
                .accessibilityLabel(ModelPickerPanel.blockedLabel(e))
        }
    }
}

/// The list inside `ModelPicker`'s panel. Usable on its own (e.g. embedded in a sheet).
struct ModelPickerPanel: View {
    let task: ModelTask
    var requires: ModelRequirement = []
    var selection: ModelChoice?
    let onSelect: (ModelChoice) -> Void
    let onOpenModels: () -> Void

    @Environment(AppDependencies.self) private var deps

    private var shelf: ModelShelf { deps.modelShelf }

    var body: some View {
        // Downloaded first, then by name (`manifests(for:)` sorts them so).
        let models = shelf.manifests(for: task, requiring: requires)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(models) { row($0) }
                    if models.isEmpty {
                        Text("No model can do this yet.").textRole(.caption).padding(Theme.Space.m)
                    }
                }
                .padding(Theme.Space.s)
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .task {
            await shelf.refreshAssessments(for: models)
            await shelf.refreshRuntimes(for: models, requiring: requires)
        }
    }

    private var footer: some View {
        HStack {
            Text(requirementNote).textRole(.caption, color: .textTertiary).lineLimit(1)
            Spacer()
            Button("Manage models", systemImage: "arrow.up.right", action: onOpenModels)
                .buttonStyle(.ghost)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .top) { Hairline() }
    }

    private var requirementNote: String {
        var parts: [String] = []
        if requires.contains(.cloning) { parts.append("clone voices") }
        if requires.contains(.voiceDesign) { parts.append("design voices") }
        if requires.contains(.wordTimestamps) { parts.append("time each word") }
        if requires.contains(.styleInstruction) { parts.append("take style direction") }
        return parts.isEmpty ? "" : "Models that " + parts.joined(separator: " and ")
    }

    private func row(_ m: ModelManifest) -> some View {
        let selected = selection?.modelID == m.id
        let variant = selected ? m.variant(selection?.variantID) : shelf.preferredVariant(m)
        let downloaded = shelf.isDownloaded(m, variantID: variant.id)
        let onDisk = m.variants.filter { shelf.isDownloaded(m, variantID: $0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            PickerRow(isSelected: selected, action: { onSelect(ModelChoice(modelID: m.id, variantID: variant.id)) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).textRole(.headline, color: downloaded ? .textPrimary : .textSecondary).lineLimit(1)
                    Text(m.summary).textRole(.caption, color: .textTertiary).lineLimit(1)
                    notes(m, variant: variant)
                }
                .help(details(m, variant: variant))
                Spacer(minLength: Theme.Space.s)
                status(variant, downloaded: downloaded)
            }
            if selected, onDisk.count > 1 {
                variantStrip(m, variants: onDisk)
                    .padding(.leading, 10)
                    .padding(.bottom, 6)
            }
        }
    }

    /// "On this Mac" with a quiet check, or the download size.
    @ViewBuilder private func status(_ variant: ModelVariant, downloaded: Bool) -> some View {
        if downloaded {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                Text("On this Mac").textRole(.caption, color: .textTertiary)
            }
            .foregroundStyle(Color.textTertiary)
            .fixedSize()
        } else {
            Text(Bytes.file(variant.downloadBytes)).textRole(.monoSmall, color: .textSecondary)
                .fixedSize()
                .help("Download size")
        }
    }

    /// Only what needs the user's attention: a non-commercial license, memory that won't comfortably fit,
    /// a runtime that can't run here.
    @ViewBuilder private func notes(_ m: ModelManifest, variant: ModelVariant) -> some View {
        let nonCommercial = m.license.commercialUse == false
        let fit = shelf.assessment(m, variantID: variant.id)
        let memory = Self.memoryNote(fit)
        let blocked = blockedError(m)
        if nonCommercial || memory != nil || blocked != nil {
            HStack(spacing: Theme.Space.s) {
                if nonCommercial {
                    Text("Non-commercial").textRole(.caption, color: Tone.warning.textColor)
                        .help(m.license.summary ?? m.license.name)
                }
                if let memory {
                    Text(memory).textRole(.caption, color: (fit?.verdict == .wontFit ? Tone.danger : Tone.warning).textColor)
                        .help(fit?.summary ?? "")
                }
                if let blocked {
                    Text(Self.blockedLabel(blocked)).textRole(.caption, color: Tone.warning.textColor)
                        .help(blocked.errorDescription ?? "")
                }
            }
            .lineLimit(1)
            .padding(.top, 1)
        }
    }

    private static func memoryNote(_ fit: MemoryAssessment?) -> String? {
        switch fit?.verdict {
        case .tight?: "Tight on memory"
        case .wontFit?: "Won't fit in memory"
        default: nil
        }
    }

    private func blockedError(_ m: ModelManifest) -> ServiceError? {
        if case .blocked(let e)? = shelf.runtime(for: m, requiring: requires) { return e }
        return nil
    }

    /// The engineering detail, for the tooltip: variant, runtime, memory, license.
    private func details(_ m: ModelManifest, variant: ModelVariant) -> String {
        var parts: [String] = []
        if m.variants.count > 1 { parts.append(variant.label) }
        if case .runs(let r)? = shelf.runtime(for: m, requiring: requires) { parts.append(r.displayName) }
        parts.append("\(MemoryGauge.bytes(variant.memoryBytes)) memory")
        parts.append(m.license.name)
        return parts.joined(separator: " · ")
    }

    static func blockedLabel(_ e: ServiceError) -> String {
        switch e {
        case .backendNeedsSetup: "Needs setup"
        case .backendUnavailable: "Unavailable"
        default: "Can't run"
        }
    }

    /// The downloaded variants of the selected model, by their friendly names.
    private func variantStrip(_ m: ModelManifest, variants: [ModelVariant]) -> some View {
        HStack(spacing: 6) {
            ForEach(variants) { v in
                let selected = m.variant(selection?.variantID).id == v.id
                Button {
                    onSelect(ModelChoice(modelID: m.id, variantID: v.id))
                } label: {
                    Text(v.friendlyName(in: m))
                        .textRole(.label, color: selected ? .textPrimary : .textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? Color.surface : .clear))
                        .overlay(Capsule().inset(by: 0.5).stroke(selected ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(v.label) · \(MemoryGauge.bytes(v.memoryBytes)) memory"
                      + (m.isRecommended(v) ? ". " + ModelManifest.recommendationHelp : ""))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
