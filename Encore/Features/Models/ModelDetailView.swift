import AppKit
import EncoreCore
import SwiftUI

/// A model's details: what it does, its variants and how they fit, its license (summary and the real
/// text), gates, and download / delete / reveal.
struct ModelDetailView: View {
    let manifest: ModelManifest
    let library: ModelsLibrary
    var onGetAccess: (String) -> Void
    var scrollHeight: CGFloat = 450

    @Environment(ModelDownloadCenter.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var isDeleting = false

    private var variant: ModelVariant { library.variant(of: manifest) }
    private var state: ModelDownloadState { downloads.state(manifest, variant) }

    var body: some View {
        SheetContainer(title: manifest.name, subtitle: subtitle, width: 680) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    overview
                    notices
                    variants
                    license
                    capabilities
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

    @ViewBuilder private var notices: some View {
        let gated = library.gatedRepos(manifest, variant).filter { library.gates[$0] != .open }
        if let repo = gated.first {
            GateNotice(repo: repo, state: library.gates[repo] ?? .unknown, info: library.repoInfo[repo]) { onGetAccess(repo) }
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

    @ViewBuilder private var variants: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(manifest.variants.count > 1 ? "Variants" : "Download", subtitle: manifest.variants.count > 1
                          ? "Smaller variants load faster and use less memory; larger ones can sound better." : nil)
            VStack(spacing: Theme.Space.xs) {
                ForEach(manifest.variants) { v in
                    VariantRow(manifest: manifest, variant: v, isSelected: v.id == variant.id,
                               fit: library.fits[ModelVariantKey(manifest, v)],
                               state: downloads.state(manifest, v), selectable: manifest.variants.count > 1) {
                        library.chosenVariant[manifest.id] = v.id
                        confirmingDelete = false
                    }
                }
            }
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("What it does")
            ModelChips(manifest: manifest, plan: nil, showsLicense: false)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let plan = library.plans[manifest.id] {
                    FactRow("Runs", runs(plan))
                }
                if !manifest.languages.isEmpty { FactRow("Languages", languages) }
                if !manifest.presetVoices.isEmpty { FactRow("Preset voices", voices) }
                if let ref = manifest.reference { FactRow("Reference clip", reference(ref)) }
                if !manifest.expressiveTags.isEmpty {
                    FactRow("Tags", manifest.expressiveTags.prefix(8).map(\.tag).joined(separator: " ")
                            + (manifest.expressiveTags.count > 8 ? " …" : ""), mono: true)
                }
                FactRow("Sample rate", String(format: manifest.sampleRate % 1000 == 0 ? "%.0f kHz" : "%.1f kHz",
                                              Double(manifest.sampleRate) / 1000), mono: true)
            }
            .padding(.top, Theme.Space.xs)
        }
    }

    private func runs(_ plan: ModelsLibrary.RuntimePlan) -> String {
        switch plan {
        case .native: "Natively on Apple silicon (MLX Swift)"
        case .python: "In Encore's Python helper (mlx-audio)"
        case .pythonUnavailable: "In Encore's Python helper, which isn't set up yet"
        }
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

    private var license: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("License") {
                LicenseChip(license: manifest.license)
            }
            if let summary = manifest.license.summary {
                Text(summary).textRole(.body).fixedSize(horizontal: false, vertical: true)
            }
            KeyValueRow("Commercial use") {
                switch manifest.license.commercialUse {
                case true?: Text("Allowed").textRole(.label, color: .mint)
                case false?: Text("Not allowed").textRole(.label, color: .velvet)
                case nil: Text("Check the license").textRole(.label, color: .textSecondary)
                }
            }
            LicenseTextBox(state: library.licenses[manifest.id], repo: ModelsLibrary.licenseRepo(manifest, variant),
                           fallbackURL: manifest.license.url.flatMap(URL.init(string:))) {
                library.licenses[manifest.id] = nil
                Task { await library.loadDetails(manifest, variant, hub: downloads.service) }
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        if confirmingDelete {
            Text("Remove \(Bytes.file(onDisk)) from this Mac?").textRole(.label, color: .textSecondary)
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
            if case .notDownloaded = state {
                Button("Download \(Bytes.file(variant.downloadBytes))", systemImage: "arrow.down") {
                    downloads.download(manifest, variant)
                }
                .buttonStyle(.primary)
            } else {
                DownloadControl(manifest: manifest, variant: variant, onGetAccess: onGetAccess)
            }
        }
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
                                      : "\(manifest.name) removed; its files are shared with another model", tone: .success, symbol: "trash")
            } catch {
                toasts.show(error.localizedDescription, tone: .danger)
            }
        }
    }
}

/// A fact about the model: key on the left, prose on the right.
private struct FactRow: View {
    let key: String
    let value: String
    var mono = false
    init(_ key: String, _ value: String, mono: Bool = false) { self.key = key; self.value = value; self.mono = mono }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(key).textRole(.label, color: .textTertiary)
                .frame(width: 112, alignment: .leading)
            Text(value).textRole(mono ? .mono : .body, color: .textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One selectable variant: label, sizes, fit and whether it's on this Mac.
private struct VariantRow: View {
    let manifest: ModelManifest
    let variant: ModelVariant
    let isSelected: Bool
    let fit: ModelsLibrary.Fit?
    let state: ModelDownloadState
    let selectable: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if selectable {
                Circle()
                    .strokeBorder(isSelected ? Color.tungsten : Color.hairlineStrong, lineWidth: 1.5)
                    .background(Circle().fill(isSelected ? Color.tungsten : .clear).padding(4))
                    .frame(width: 14, height: 14)
            }
            HStack(spacing: 6) {
                Text(variant.label).font(.ui(13, weight: .semibold)).foregroundStyle(.textPrimary)
                if variant.recommended == true { Chip("Recommended", tone: .accent) }
            }
            Spacer(minLength: Theme.Space.s)
            Text(Bytes.file(variant.downloadBytes)).textRole(.mono, color: .textSecondary)
                .frame(width: 74, alignment: .trailing)
            FitLabel(fit: fit, memoryBytes: variant.memoryBytes)
                .frame(width: 170, alignment: .trailing)
            Group {
                switch state {
                case .downloaded: StatusBadge("On Mac", tone: .success)
                case .downloading(let p): Text("\(Int(p.fractionCompleted * 100))%").textRole(.monoSmall, color: .tungsten)
                case .partial: StatusBadge("Partial", tone: .warning)
                default: EmptyView()
                }
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                .fill(isSelected && selectable ? Color.tungsten.opacity(0.07) : (isHovered && selectable ? Color.textPrimary.opacity(0.03) : Color.surfaceSunken.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .strokeBorder(isSelected && selectable ? Color.tungsten.opacity(0.35) : Color.hairline))
        }
        .contentShape(Rectangle())
        .onTapGesture { if selectable { select() } }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The fetched license text, with loading, failed and empty states.
struct LicenseTextBox: View {
    let state: ModelsLibrary.LicenseState?
    let repo: String
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
                            Text(text)
                                .font(.mono(11))
                                .foregroundStyle(.textSecondary)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Space.m)
                        }
                        .frame(maxHeight: 190)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("The repository has no license text. Read it at the source.").textRole(.caption)
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
                if let url = loadedURL ?? fallbackURL { LinkButton(title: "Read the license", url: url) }
            }
        }
    }

    private var loadedURL: URL? { if case .loaded(let l)? = state { return l.url } else { return nil } }

    private func source(_ s: HubLicenseText.Source) -> String {
        switch s {
        case .repoFile(let path): "From \(path) in \(repo)"
        case .modelCard: "From the model card of \(repo)"
        case .standard(let id): "Standard text of \(id), from spdx.org"
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
    var getAccess: () -> Void

    var body: some View {
        switch state {
        case .pending(let message):
            Banner(.neutral, title: "Access requested — waiting for approval",
                   message: "The authors of \(repo) review each request themselves. \(message)") {
                Button("Check again", action: getAccess).buttonStyle(.secondary).controlSize(.small)
            }
        default:
            Banner(.warning, title: "Accept the terms on Hugging Face first",
                   message: "\(repo) is gated: its authors ask you to accept their conditions"
                       + ((info?.gate ?? .auto) == .manual ? " and approve each request." : " before downloading. Access is granted as soon as you accept.")) {
                Button("Get access", systemImage: "lock.open", action: getAccess).buttonStyle(.secondary).controlSize(.small)
            }
        }
    }
}

/// An underlined-on-hover text link with an outward arrow.
struct LinkButton: View {
    let title: String
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text(title).underline(isHovered)
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
            }
            .font(.ui(12, weight: .medium))
            .foregroundStyle(isHovered ? Color.tungsten : Color.tungsten.opacity(0.85))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.absoluteString)
    }
}
