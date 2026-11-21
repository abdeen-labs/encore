import AppKit
import EncoreCore
import SwiftUI

/// The catalog: every model grouped by what it's for, with its download state and only the facts that matter at
/// a glance; details and the gated-model flow in sheets; what's in memory on top, while anything is.
struct ModelsScreen: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(ModelDownloadCenter.self) private var downloads
    @Environment(RuntimeStatus.self) private var runtimeStatus
    @Environment(EncoreService.self) private var service
    @Environment(\.modelsLibraryOverride) private var libraryOverride

    @State private var ownLibrary = ModelsLibrary()
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var detailModelID: String?
    @State private var gate: GateRequest?

    enum Scope: String, CaseIterable { case all = "All", onMac = "On this Mac" }

    private var library: ModelsLibrary { libraryOverride ?? ownLibrary }

    var body: some View {
        let blocked = pythonBlocked
        let visible = visibleModels
        ScreenScaffold(.models) {
            if !runtimeStatus.loaded.isEmpty {
                LoadedModelsStrip()
            }
            if !blocked.isEmpty {
                pythonNotice(blocked)
            }
            if visible.isEmpty {
                emptyState
            }
            ForEach(ModelGroup.allCases) { group in
                let models = visible.filter { $0.group == group }
                if !models.isEmpty { section(group, models) }
            }
        } actions: {
            SearchField(text: $query, prompt: "Search models")
                .frame(width: 170)
            SegmentedControl(selection: $scope, options: Scope.allCases) { $0.rawValue }
                .fixedSize()
        }
        .stageSheet(isPresented: detailBinding) {
            if let id = detailModelID, let manifest = deps.catalog.model(id) {
                ModelDetailView(manifest: manifest, library: library) { repo in openGate(manifest, repo: repo, fromDetail: true) }
            }
        }
        .stageSheet(isPresented: gateBinding) {
            if let gate, let manifest = deps.catalog.model(gate.modelID) {
                GateFlowView(request: gate, manifest: manifest, library: library)
            }
        }
        .onAppear {
            // A download started elsewhere (a first-run stage) may already be waiting at a gate: take it from here.
            guard !library.isFixture else { return }
            openGateForFailure(in: gatedFailures)
        }
        .task { await refresh() }
        .onChange(of: runtimeStatus.loaded) { Task { await library.refreshFits(catalog: deps.catalog, runtime: service.runtime) } }
        .onChange(of: gatedFailures) { old, new in
            // A download just hit a gate: walk the user through it (unless something else is on screen).
            openGateForFailure(in: new.subtracting(old))
        }
    }

    private func refresh() async {
        guard !library.isFixture else { return }
        await downloads.refresh()
        await library.refreshPlans(catalog: deps.catalog, shelf: deps.modelShelf)
        await library.refreshFits(catalog: deps.catalog, runtime: service.runtime)
    }

    // MARK: Content

    private func section(_ group: ModelGroup, _ models: [ModelManifest]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(group.title).textRole(.section)
                    .accessibilityAddTraits(.isHeader)
                Text(group.subtitle).textRole(.caption)
                    .lineLimit(1)
            }
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, manifest in
                    if index > 0 { Hairline().padding(.horizontal, Theme.Space.l) }
                    ModelRow(manifest: manifest, library: library) {
                        detailModelID = manifest.id
                    } onGetAccess: { repo in
                        openGate(manifest, repo: repo, fromDetail: false)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .surface()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if scope == .onMac && query.isEmpty {
            EmptyState(symbol: "arrow.down.circle", title: "Nothing downloaded yet",
                       message: "Models you download appear here. Everything runs on this Mac.") {
                Button("Show all models") { scope = .all; query = "" }.buttonStyle(.secondary)
            }
        } else {
            EmptyState(symbol: "magnifyingglass", title: "No models match",
                       message: "Try another name, language or capability.", style: .plain) {
                Button("Show all models") { scope = .all; query = "" }.buttonStyle(.secondary)
            }
        }
    }

    /// Models that need the Python helper, which isn't available.
    private var pythonBlocked: [ModelManifest] {
        deps.catalog.models.filter {
            if case .pythonUnavailable? = library.plans[$0.id] { return true }
            return false
        }
    }

    /// One warning for every model the helper blocks: a title and one line on what to do.
    @ViewBuilder private func pythonNotice(_ blocked: [ModelManifest]) -> some View {
        if let first = blocked.first, case .pythonUnavailable(let message)? = library.plans[first.id] {
            let names = blocked.map(\.name)
            let needsSetup = library.python.map { (lookup: PythonRuntime.Lookup) -> Bool in
                if case .needsSetup = lookup { return true }
                return false
            } ?? false
            Banner(.warning,
                   title: names.count == 1 ? "\(names[0]) needs the Python helper" : "\(names.count) models need the Python helper",
                   message: needsSetup ? "Run the setup script in the Encore repository, then try again." : message) {
                if needsSetup {
                    Button("Copy command", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Scripts/setup-python-runtime.sh", forType: .string)
                    }
                    .buttonStyle(.secondary).controlSize(.small)
                }
            }
            .help(names.count > 1 ? "\(names.formatted(.list(type: .and))). \(message)" : message)
        }
    }

    private var visibleModels: [ModelManifest] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return deps.catalog.models.filter { m in
            if scope == .onMac {
                let onMac = m.variants.contains { v in
                    switch downloads.state(m, v) {
                    case .downloaded, .partial, .downloading: true
                    case .failed(_, let bytes): bytes > 0
                    default: false
                    }
                }
                if !onMac { return false }
            }
            guard !q.isEmpty else { return true }
            let haystack = ([m.name, m.family, m.summary, m.license.name, m.group.title]
                + m.languages.map(\.name) + m.variants.map(\.repo)).joined(separator: " ").lowercased()
            return q.split(separator: " ").allSatisfy { haystack.contains($0) }
        }
        .sorted { a, b in
            // Downloaded first within a group, then the catalog's order.
            let da = a.variants.contains { downloads.state(a, $0).isDownloaded }
            let db = b.variants.contains { downloads.state(b, $0).isDownloaded }
            return da && !db
        }
    }

    private var gatedFailures: Set<ModelVariantKey> {
        Set(downloads.states.compactMap { key, state in state.error?.gatedRepo != nil ? key : nil })
    }

    // MARK: Sheets

    /// Opens the gate sheet for the first of `keys` that is waiting at a gate, unless a sheet is already up.
    private func openGateForFailure(in keys: Set<ModelVariantKey>) {
        guard gate == nil, detailModelID == nil else { return }
        let ordered = keys.sorted { ($0.modelID, $0.variantID) < ($1.modelID, $1.variantID) }
        for key in ordered {
            guard let manifest = deps.catalog.model(key.modelID),
                  case .failed(let error, _) = downloads.states[key], let repo = error.gatedRepo else { continue }
            library.chosenVariant[manifest.id] = key.variantID
            gate = GateRequest(modelID: manifest.id, variantID: key.variantID, repo: repo)
            return
        }
    }

    private func openGate(_ manifest: ModelManifest, repo: String, fromDetail: Bool) {
        let request = GateRequest(modelID: manifest.id, variantID: library.variant(of: manifest).id, repo: repo)
        if fromDetail {
            detailModelID = nil
            // Let the details sheet leave before the gate sheet arrives.
            Task { try? await Task.sleep(for: .milliseconds(350)); gate = request }
        } else {
            gate = request
        }
    }

    private var detailBinding: Binding<Bool> {
        Binding(get: { detailModelID != nil }, set: { if !$0 { detailModelID = nil } })
    }

    private var gateBinding: Binding<Bool> {
        Binding(get: { gate != nil }, set: { if !$0 { gate = nil } })
    }
}
