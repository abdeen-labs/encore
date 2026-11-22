import AppKit
import EncoreCore
import SwiftUI

/// A model's details, and the home of its engineering detail: what it does, its variants and how they fit, its
/// license (summary and the real text), how it runs, gates, and download / delete / reveal.
struct ModelDetailView: View {
    let manifest: ModelManifest
    let library: ModelsLibrary
    var onGetAccess: (String) -> Void
    var scrollHeight: CGFloat = 450

    @Environment(ModelDownloadCenter.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppDependencies.self) private var deps: AppDependencies?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var isDeleting = false

    private var variant: ModelVariant { library.variant(of: manifest) }
    private var state: ModelDownloadState { downloads.state(manifest, variant) }
    private var isGatedFailure: Bool { state.error?.gatedRepo != nil }

    var body: some View {
        SheetContainer(title: manifest.name, subtitle: subtitle, width: 680) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    overview
                    notices
                    if manifest.variants.count > 1 { variants }
                    license
                    details
                }
                .padding(.vertical, Theme.Space.xs)
                .padding(.trailing, Theme.Space.s)
            }
            .scrollIndicators(.automatic)
            .frame(height: scrollHeight)
        } actions: {
            actions
        }
        .task(id: variant.id) { await library.loadDetails(manifest, variant, hub: downloads.service) }
    }

    private var subtitle: String { "\(manifest.family) · \(manifest.group.title)" }

    // MARK: Sections

    private var overview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(manifest.summary).textRole(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.m) {
                if let home = manifest.homepage.flatMap(URL.init(string:)) {
                    LinkButton(title: "Project page", url: home)
                }
                LinkButton(title: "Hugging Face", url: downloads.service.modelPageURL(variant.repo))
            }
        }
    }

    /// Banners only for what needs action: a gate, a missing helper, a tight or impossible fit, a failed download.
    @ViewBuilder private var notices: some View {
        let gated = library.gatedRepos(manifest, variant).filter { library.gates[$0] != .open }
        if let repo = gated.first {
            // When the download already stopped at the gate, "Get access" is the sheet's primary action instead.
            GateNotice(repo: repo, state: library.gates[repo] ?? .unknown, info: library.repoInfo[repo],
                       showsAction: !isGatedFailure) { onGetAccess(repo) }
        }
        if case .pythonUnavailable(let message)? = library.plans[manifest.id] {
            Banner(.warning, title: "Needs the Python helper", message: message)
        }
        if let fit = library.fits[ModelVariantKey(manifest, variant)], fit.verdict != .comfortable, !fit.alreadyLoaded {
            Banner(fit.verdict == .wontFit ? .danger : .warning,
                   title: fit.verdict == .wontFit ? "Won't fit comfortably in memory" : "A tight fit in memory",
                   message: fit.summary)
        }
        if case .failed(let error, _) = state, error.gatedRepo == nil {
            Banner(.danger, title: "Download failed", message: error.localizedDescription)
        }
    }

    private var variants: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Variants", subtitle: "Smaller variants load faster and use less memory; larger ones can sound better.")
            VStack(spacing: Theme.Space.xs) {
                ForEach(manifest.variants) { v in
                    VariantRow(manifest: manifest, variant: v, isSelected: v.id == variant.id,
                               fit: library.fits[ModelVariantKey(manifest, v)],
                               state: downloads.state(manifest, v)) {
                        library.chosenVariant[manifest.id] = v.id
                        confirmingDelete = false
                    }
                }
            }
        }
    }

    private var license: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("License") {
                if manifest.isNonCommercial { Chip("Non-commercial", tone: .warning) }
            }
            if let summary = manifest.license.summary {
                Text(summary).textRole(.body).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                fact("License", manifest.license.name)
                fact("Commercial use", commercialUse)
            }
            LicenseTextBox(state: library.licenses[manifest.id], repo: ModelsLibrary.licenseRepo(manifest, variant),
                           licenseName: manifest.license.name, fallbackURL: manifest.license.url.flatMap(URL.init(string:))) {
                library.licenses[manifest.id] = nil
                Task { await library.loadDetails(manifest, variant, hub: downloads.service) }
            }
        }
    }

    private var commercialUse: String {
        switch manifest.license.commercialUse {
        case true?: "Allowed"
        case false?: "Not allowed"
        case nil: "Check the license"
        }
    }

    /// What the list leaves out: capabilities in full, reach, how it runs and what it costs.
    private var details: some View {
        let capabilities = ModelFacts.capabilities(manifest)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Details")
            VStack(spacing: 0) {
                if !capabilities.isEmpty { fact("Capabilities", capabilities.joined(separator: ", ")) }
                if !manifest.languages.isEmpty { fact("Languages", languages) }
                if !manifest.presetVoices.isEmpty { fact("Built-in voices", voices) }
                if let ref = manifest.reference { fact("Reference clip", reference(ref)) }
                if !manifest.expressiveTags.isEmpty {
                    fact("Expressive tags", manifest.expressiveTags.prefix(8).map(\.tag).joined(separator: " ")
                         + (manifest.expressiveTags.count > 8 ? " …" : ""))
                }
                if let plan = library.plans[manifest.id] { fact("Runs", runs(plan)) }
                if manifest.variants.count == 1 {
                    KeyValueRow("Variant") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(variant.friendlyName(in: manifest)).textRole(.body)
                            if variant.friendlyName(in: manifest) != variant.label {
                                Text(variant.label).textRole(.monoSmall, color: .textTertiary)
                            }
                        }
                    }
                    figure("Download size", Bytes.file(variant.downloadBytes))
                }
                figure("Memory while generating", Bytes.memory(variant.memoryBytes))
                figure("Sample rate", String(format: manifest.sampleRate % 1000 == 0 ? "%.0f kHz" : "%.1f kHz",
                                             Double(manifest.sampleRate) / 1000))
                figure("Repository", variant.allRepos.joined(separator: "\n"))
            }
        }
    }

    /// A fact in words.
    private func fact(_ key: String, _ value: String) -> some View {
        KeyValueRow(key) { Text(value).textRole(.body).textSelection(.enabled) }
    }

    /// A figure or an identifier.
    private func figure(_ key: String, _ value: String) -> some View {
        KeyValueRow(key) { Text(value).textRole(.mono).textSelection(.enabled) }
    }

    /// Where the model runs, and why when that's the runtime it runs best in.
    private func runs(_ plan: ModelsLibrary.RuntimePlan) -> String {
        let place: String
        let runtime: EngineRuntime
        switch plan {
        case .native: place = "On this Mac's GPU"; runtime = .mlxSwift
        case .python: place = "In the bundled Python helper"; runtime = .python
        case .pythonUnavailable: return "In the Python helper, which isn't set up yet"
        }
        guard let pick = BestRuntime.pick(for: manifest.engine) else { return place }
        if pick.runtime == runtime { return "\(place), where it \(pick.reason)" }
        // Automatic had to use the other runtime (the Python helper isn't set up, say).
        guard deps?.modelShelf.missedBestRuntime(for: manifest) != nil else { return place }
        return "\(place) for now. It runs best \(BestRuntimeNote.place(pick.runtime)), where it \(pick.reason), "
            + "but that isn't available on this Mac."
    }

    private var languages: String {
        let names = manifest.languages.map(\.name)
        if names.count <= 10 { return names.joined(separator: ", ") }
        return names.prefix(8).joined(separator: ", ") + " and \(names.count - 8) more"
    }

    private var voices: String {
        let names = manifest.presetVoices.map(\.name)
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? "\(names.count), including \(shown)" : shown
    }

    private func reference(_ r: ReferenceSpec) -> String {
        let span = "\(Self.seconds(r.minSeconds))–\(Self.seconds(r.maxSeconds)) s of clean speech"
        switch r.transcript {
        case .required: return span + "; transcript required"
        case .recommended: return span + "; transcript recommended"
        case .unused: return span
        }
    }

    static func seconds(_ s: Double) -> String { s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s) }

    // MARK: Actions

    /// The sheet's one primary action is the next download step: download, resume, retry or get access.
    @ViewBuilder private var actions: some View {
        if confirmingDelete {
            Text(deleteQuestion).textRole(.label, color: .textSecondary)
            Button("Keep") { confirmingDelete = false }.buttonStyle(.ghost)
            Button("Delete", systemImage: "trash") { delete() }
                .buttonStyle(.destructive)
                .disabled(isDeleting)
        } else {
            if let dir = snapshotDirectory {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .buttonStyle(.ghost)
            }
            if onDisk > 0, !state.isDownloading {
                Button("Delete…", systemImage: "trash") { confirmingDelete = true }
                    .buttonStyle(.ghost)
            }
            switch state {
            case .notDownloaded:
                Button("Download", systemImage: "arrow.down") { downloads.download(manifest, variant) }
                    .buttonStyle(.primary)
            case .partial(let bytes):
                Text("\(Bytes.file(bytes)) of \(Bytes.file(variant.downloadBytes))").textRole(.monoSmall, color: .textTertiary)
                Button("Resume", systemImage: "arrow.clockwise") { downloads.download(manifest, variant) }
                    .buttonStyle(.primary)
            case .failed(let error, _):
                if let repo = error.gatedRepo {
                    Button("Get access", systemImage: "lock.open") { onGetAccess(repo) }
                        .buttonStyle(.primary)
                } else {
                    Button("Retry", systemImage: "arrow.clockwise") { downloads.retry(manifest, variant) }
                        .buttonStyle(.primary)
                }
            case .downloaded:
                // With several variants, each variant row already says which ones are on this Mac.
                if manifest.variants.count == 1 { StatusBadge("On this Mac", tone: .success) }
            case .unknown, .downloading:
                DownloadControl(manifest: manifest, variant: variant, onGetAccess: onGetAccess)
            }
        }
    }

    /// Says how much goes, and names any other model stored in the same files.
    private var deleteQuestion: String {
        let plan = downloads.deletionPlan(manifest, variant)
        let question = "Remove \(Bytes.file(plan.bytes)) from this Mac?"
        guard !plan.alsoRemoves.isEmpty else { return question }
        let names = plan.alsoRemoves.map(\.name).formatted(.list(type: .and))
        return "\(question) \(names) \(plan.alsoRemoves.count == 1 ? "uses" : "use") the same files and will be removed too."
    }

    private var onDisk: Int64 {
        switch state {
        case .partial(let b), .downloaded(let b), .failed(_, let b): b
        default: 0
        }
    }

    private var snapshotDirectory: URL? {
        guard state.isDownloaded else { return nil }
        return downloads.statuses[ModelVariantKey(manifest, variant)]?.repoDirectories?[variant.repo]
    }

    private func delete() {
        isDeleting = true
        Task {
            defer { isDeleting = false; confirmingDelete = false }
            do {
                let freed = try await downloads.delete(manifest, variant)
                toasts.show(freed > 0 ? "Deleted \(manifest.name) · freed \(Bytes.file(freed))"
                                      : "\(manifest.name) removed; the files it shares with another model were kept",
                            tone: .success, symbol: "trash")
            } catch {
                toasts.show(error.localizedDescription, tone: .danger)
            }
        }
    }
}

/// One selectable variant: its friendly name and raw label, whether it's the one for this Mac, its size, its fit
/// (only when tight or won't fit), and whether it's on this Mac.
private struct VariantRow: View {
    let manifest: ModelManifest
    let variant: ModelVariant
    let isSelected: Bool
    let fit: ModelsLibrary.Fit?
    let state: ModelDownloadState
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        let friendly = variant.friendlyName(in: manifest)
        HStack(spacing: Theme.Space.m) {
            Circle()
                .strokeBorder(isSelected ? Color.tungsten : Color.hairlineStrong, lineWidth: 1.5)
                .background(Circle().fill(isSelected ? Color.tungsten : .clear).padding(4))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(friendly).textRole(.headline).lineLimit(1)
                    if friendly != variant.label {
                        Text(variant.label).textRole(.monoSmall, color: .textTertiary).lineLimit(1)
                    }
                }
                if manifest.isRecommended(variant) {
                    Text("Recommended for this Mac").textRole(.caption)
                        .help(ModelManifest.recommendationHelp)
                }
            }
            Spacer(minLength: Theme.Space.s)
            FitNote(fit: fit)
            Text(Bytes.file(variant.downloadBytes)).textRole(.mono, color: .textSecondary)
                .frame(width: 74, alignment: .trailing)
                .help("Download size")
            Group {
                switch state {
                case .downloaded: StatusBadge("On this Mac", tone: .success)
                case .downloading(let p): Text("\(Int(p.fractionCompleted * 100))%").textRole(.monoSmall, color: .textSecondary)
                case .partial: Text("Partly downloaded").textRole(.caption, color: .textTertiary).lineLimit(1)
                default: Color.clear.frame(height: 1) // keeps the column, so sizes line up across rows
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
            shape.fill(isSelected ? Color.textPrimary.opacity(0.05) : (isHovered ? Color.textPrimary.opacity(0.03) : Color.surfaceSunken.opacity(0.6)))
                .overlay(shape.strokeBorder(isSelected ? Color.hairlineStrong : Color.hairline))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Choose", select)
    }
}

/// The fetched license text, with loading, failed and empty states.
struct LicenseTextBox: View {
    let state: ModelsLibrary.LicenseState?
    let repo: String
    /// Shown when there's no text to show (no license file and no bundled standard text).
    let licenseName: String
    let fallbackURL: URL?
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Group {
                switch state {
                case nil, .loading?:
                    HStack(spacing: Theme.Space.s) {
                        ActivityIndicator(size: 14)
                        Text("Fetching the license from Hugging Face…").textRole(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                case .failed(let message)?:
                    VStack(spacing: Theme.Space.s) {
                        Text("Couldn't fetch the license text. \(message)").textRole(.caption)
                            .multilineTextAlignment(.center)
                        Button("Try again", action: retry).buttonStyle(.secondary).controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                case .loaded(let license)?:
                    if let text = license.text {
                        ScrollView {
                            Text(text).textRole(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Space.m)
                        }
                        .frame(maxHeight: 190)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 4) {
                            Text(licenseName).textRole(.headline)
                            Text("Encore doesn't have this license's text. Read it on the model's page.").textRole(.caption)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 64)
                    }
                }
            }
            .surface(.sunken, radius: Theme.Radius.m)

            HStack(spacing: Theme.Space.m) {
                if case .loaded(let license)? = state {
                    Text(source(license.source)).textRole(.caption, color: .textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let url = loadedURL ?? fallbackURL { LinkButton(title: hasNoText ? "Open the model's page" : "Read the license", url: url) }
            }
        }
    }

    private var loadedURL: URL? { if case .loaded(let l)? = state { return l.url } else { return nil } }
    private var hasNoText: Bool { if case .loaded(let l)? = state { return l.text == nil } else { return false } }

    private func source(_ s: HubLicenseText.Source) -> String {
        switch s {
        case .repoFile(let path): "From \(path) in \(repo)"
        case .modelCard: "From the model card of \(repo)"
        case .standard(let id): "Standard text of \(id), bundled with Encore"
        case .gatePrompt: "From the terms shown on \(repo)'s gate"
        case .none: "No license text published"
        }
    }
}

/// A gate on one of the model's repos, in plain words.
struct GateNotice: View {
    let repo: String
    let state: ModelsLibrary.GateState
    let info: HubRepoInfo?
    /// False when the sheet's action row already offers "Get access".
    var showsAction = true
    var getAccess: () -> Void

    var body: some View {
        switch state {
        case .pending(let message):
            Banner(.neutral, title: "Access requested, waiting for approval",
                   message: "The authors of \(repo) review each request themselves. \(message)") {
                Button("Check again", action: getAccess).buttonStyle(.secondary).controlSize(.small)
            }
        default:
            Banner(.warning, title: "Accept the terms on Hugging Face first",
                   message: "\(repo) is gated: its authors ask you to accept their conditions"
                       + ((info?.gate ?? .auto) == .manual ? " and approve each request." : " before downloading. Access is granted as soon as you accept.")) {
                if showsAction {
                    Button("Get access", systemImage: "lock.open", action: getAccess).buttonStyle(.secondary).controlSize(.small)
                }
            }
        }
    }
}

/// A text link with an outward arrow, underlined on hover.
struct LinkButton: View {
    let title: String
    let url: URL
    @State private var isHovered = false

    var body: some View {
        let color: Color = isHovered ? .textPrimary : .textSecondary
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text(title).underline(isHovered).textRole(.label, color: color)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.absoluteString)
    }
}
