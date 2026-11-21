import EncoreCore
import SwiftUI

/// Chooses a model and variant for a task. The panel lists every model that can do the job — downloaded or not —
/// with what matters at the moment of choice: on disk or not, download size, whether it fits in memory now,
/// the license (non-commercial marked), and whether it runs natively or in the Python helper.
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
        let variant = m.map { $0.variant(selection?.variantID) }
        PickerPlate(label: "Model", symbol: "cpu",
                    value: m?.name ?? "Choose a model",
                    detail: m.flatMap { $0.variants.count > 1 ? variant?.label : nil },
                    isOpen: isOpen, action: { isOpen.toggle() }) {
            if let m, !shelf.isDownloaded(m, variantID: selection?.variantID), shelf.hasScanned {
                Circle().fill(Color.footlight).frame(width: 7, height: 7)
                    .glow(.footlight, radius: 4, intensity: 0.6)
                    .help("Not downloaded yet")
                    .accessibilityLabel("Not downloaded")
            } else if let m, m.license.commercialUse == false {
                Text("NC").font(.ui(9.5, weight: .bold)).tracking(1).foregroundStyle(Color.footlight).fixedSize()
                    .help("Non-commercial license: \(m.license.name)")
            }
            if let m { RuntimeMark(verdict: shelf.runtime(for: m, requiring: requires) ?? shelf.runtime(for: m)) }
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

/// The runtime a model will use, as a small glyph for tight spots (the picker plate): a bolt for native,
/// a box for the Python helper, a warning when it can't run here. The tooltip says which.
struct RuntimeMark: View {
    let verdict: RuntimeVerdict?

    var body: some View {
        switch verdict {
        case .runs(let r)?:
            Image(systemName: r == .mlxSwift ? "bolt.fill" : "shippingbox.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(r == .mlxSwift ? Color.mint.opacity(0.85) : Color.textSecondary)
                .help(r == .mlxSwift ? "Runs natively in Encore" : "Runs in Encore's Python helper")
                .accessibilityLabel(r.displayName)
        case .blocked(let e)?:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.footlight)
                .help(e.errorDescription ?? ModelPickerPanel.blockedLabel(e))
                .accessibilityLabel(ModelPickerPanel.blockedLabel(e))
        case nil:
            EmptyView()
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
        let models = shelf.manifests(for: task, requiring: requires)
        let ready = models.filter(shelf.isAnyVariantDownloaded)
        let rest = models.filter { !shelf.isAnyVariantDownloaded($0) }
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !ready.isEmpty {
                        PanelHeading(title: "On this Mac", count: ready.count)
                        ForEach(ready) { row($0) }
                    }
                    if !rest.isEmpty {
                        PanelHeading(title: "Not downloaded", count: rest.count)
                        ForEach(rest) { row($0) }
                    }
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
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
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
        return VStack(alignment: .leading, spacing: 0) {
            PickerRow(isSelected: selected, action: { onSelect(ModelChoice(modelID: m.id, variantID: variant.id)) }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(m.name).textRole(.headline, color: downloaded ? .textPrimary : .textSecondary)
                        if m.variants.count > 1 { Text(variant.label).textRole(.monoSmall, color: .textTertiary) }
                        Spacer(minLength: 4)
                        runtimeBadge(m)
                    }
                    Text(m.summary).textRole(.caption, color: .textTertiary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    facts(m, variant: variant, downloaded: downloaded)
                }
            }
            if selected, m.variants.count > 1 {
                variantStrip(m)
                    .padding(.leading, 10)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private func runtimeBadge(_ m: ModelManifest) -> some View {
        switch shelf.runtime(for: m, requiring: requires) {
        case .runs(let r)?:
            Text(r.displayName)
                .textRole(.monoSmall, color: r == .mlxSwift ? .mint : .textSecondary)
                .help(r == .mlxSwift ? "Runs natively in Encore" : "Runs in Encore's Python helper")
        case .blocked(let e)?:
            Text(Self.blockedLabel(e)).textRole(.monoSmall, color: .footlight)
                .help(e.errorDescription ?? "")
        case nil:
            EmptyView()
        }
    }

    static func blockedLabel(_ e: ServiceError) -> String {
        switch e {
        case .backendNeedsSetup: "Needs setup"
        case .backendUnavailable: "Unavailable"
        default: "Can't run"
        }
    }

    private func facts(_ m: ModelManifest, variant: ModelVariant, downloaded: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if downloaded {
                Label("On disk", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.ui(11, weight: .medium))
                    .foregroundStyle(Color.mint)
            } else {
                Text("\(MemoryGauge.bytes(variant.downloadBytes)) download")
                    .textRole(.monoSmall, color: .textSecondary)
            }
            fit(shelf.assessment(m, variantID: variant.id), variant: variant)
            license(m.license)
            Spacer(minLength: 0)
            if !downloaded {
                Button("Get", systemImage: "arrow.down.circle", action: onOpenModels)
                    .buttonStyle(.ghost)
                    .controlSize(.small)
                    .help("Download it in Models")
            }
        }
    }

    @ViewBuilder private func fit(_ a: MemoryAssessment?, variant: ModelVariant) -> some View {
        let size = MemoryGauge.bytes(variant.memoryBytes)
        switch a?.verdict {
        case .comfortable?:
            Text("\(size) RAM").textRole(.monoSmall, color: .textTertiary)
                .help(a?.summary ?? "")
        case .tight?:
            Label("\(size) RAM · tight", systemImage: "exclamationmark.triangle.fill")
                .font(.mono(10.5)).foregroundStyle(Color.footlight)
                .help(a?.summary ?? "")
        case .wontFit?:
            Label("\(size) RAM · won't fit", systemImage: "xmark.octagon.fill")
                .font(.mono(10.5)).foregroundStyle(Color.velvet)
                .help(a?.summary ?? "")
        case nil:
            Text("\(size) RAM").textRole(.monoSmall, color: .textTertiary)
        }
    }

    private func license(_ l: ModelLicense) -> some View {
        let nc = l.commercialUse == false
        return Text(nc ? "\(l.name) · non-commercial" : l.name)
            .font(.ui(10.5, weight: nc ? .semibold : .regular))
            .foregroundStyle(nc ? Color.footlight : Color.textTertiary)
            .lineLimit(1)
            .help(l.summary ?? l.name)
    }

    private func variantStrip(_ m: ModelManifest) -> some View {
        HStack(spacing: 6) {
            ForEach(m.variants) { v in
                let on = shelf.isDownloaded(m, variantID: v.id)
                let selected = m.variant(selection?.variantID).id == v.id
                Button {
                    onSelect(ModelChoice(modelID: m.id, variantID: v.id))
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(on ? Color.mint : Color.textTertiary.opacity(0.5)).frame(width: 5, height: 5)
                        Text(v.label).font(.ui(11, weight: selected ? .semibold : .medium))
                        if m.isRecommended(v) {
                            Image(systemName: "star.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.tungsten)
                                .accessibilityLabel("Recommended")
                        }
                        Text(MemoryGauge.bytes(v.downloadBytes)).font(.mono(9.5)).foregroundStyle(.textTertiary)
                    }
                    .foregroundStyle(selected ? Color.tungsten : .textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(selected ? Color.tungsten.opacity(0.12) : Color.surface))
                    .overlay(Capsule().strokeBorder(selected ? Color.tungsten.opacity(0.5) : Color.hairline, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help((on ? "\(v.label): on this Mac" : "\(v.label): not downloaded")
                      + (m.isRecommended(v) ? ". " + ModelManifest.recommendationHelp : ""))
            }
        }
    }
}
