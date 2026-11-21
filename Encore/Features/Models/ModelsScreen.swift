import AppKit
import EncoreCore
import SwiftUI

/// The catalog: every model grouped by what it's for, with license, runtime, memory fit and live
/// download state; details and the gated-model flow in sheets; what's in memory on top.
struct ModelsScreen: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(ModelDownloadCenter.self) private var downloads
    @Environment(RuntimeStatus.self) private var runtimeStatus
    @Environment(EncoreService.self) private var service
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelsLibraryOverride) private var libraryOverride

    @State private var ownLibrary = ModelsLibrary()
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var detailModelID: String?
    @State private var gate: GateRequest?

    enum Scope: String, CaseIterable { case all = "All", onMac = "On this Mac" }

    private var library: ModelsLibrary { libraryOverride ?? ownLibrary }

    var body: some View {
        ScreenScaffold(.models) {
            LoadedModelsStrip()
            pythonNotice
            if visibleModels.isEmpty {
                Card(padding: 0) {
                    EmptyState(symbol: scope == .onMac ? "arrow.down.circle" : "magnifyingglass",
                               title: scope == .onMac && query.isEmpty ? "Nothing downloaded yet" : "No models match",
                               message: scope == .onMac && query.isEmpty
                                   ? "Download a model below to start performing. Everything runs on this Mac."
                                   : "Try another name, language or capability.") {
                        Button("Show all models") { scope = .all; query = "" }.buttonStyle(.secondary)
                    }
                }
            }
            ForEach(ModelGroup.allCases) { group in
                let models = visibleModels.filter { $0.group == group }
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
        .task { await refresh() }
        .onChange(of: runtimeStatus.loaded) { Task { await library.refreshFits(catalog: deps.catalog, runtime: service.runtime) } }
        .onChange(of: gatedFailures) { old, new in
            // A download just hit a gate: walk the user through it (unless something else is on screen).
            guard let key = new.subtracting(old).first, gate == nil, detailModelID == nil,
                  let manifest = deps.catalog.model(key.modelID),
                  case .failed(let error, _) = downloads.states[key], let repo = error.gatedRepo else { return }
            library.chosenVariant[manifest.id] = key.variantID
            gate = GateRequest(modelID: manifest.id, variantID: key.variantID, repo: repo)
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
            SectionHeader(group.title, subtitle: group.subtitle) {
                Text("\(models.count) model\(models.count == 1 ? "" : "s")").textRole(.monoSmall, color: .textTertiary)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, manifest in
                        if index > 0 { HLine().stroke(Color.hairline).frame(height: 1).padding(.horizontal, Theme.Space.l) }
                        ModelRow(manifest: manifest, library: library) {
                            detailModelID = manifest.id
                        } onGetAccess: { repo in
                            openGate(manifest, repo: repo, fromDetail: false)
                        }
                    }
                }
            }
        }
        .padding(.top, Theme.Space.s)
    }

    @ViewBuilder private var pythonNotice: some View {
        let blocked = deps.catalog.models.filter {
            if case .pythonUnavailable = library.plans[$0.id] { return true } else { return false }
        }
        if let first = blocked.first, case .pythonUnavailable(let message)? = library.plans[first.id] {
            let names = blocked.map(\.name)
            Banner(.warning, title: names.count == 1 ? "\(names[0]) needs the Python helper"
                                                     : "\(names.count) models need the Python helper",
                   message: message) {
                if case .needsSetup? = library.python {
                    Button("Copy command", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Scripts/setup-python-runtime.sh", forType: .string)
                    }
                    .buttonStyle(.secondary).controlSize(.small)
                }
            }
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
