import EncoreCore
import SwiftUI

/// One model in the catalog: what it is, what it can do, what it costs, and where its download stands.
struct ModelRow: View {
    let manifest: ModelManifest
    let library: ModelsLibrary
    var onOpen: () -> Void
    var onGetAccess: (String) -> Void

    @Environment(ModelDownloadCenter.self) private var downloads
    @State private var isHovered = false

    private var variant: ModelVariant { library.variant(of: manifest) }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(manifest.name).textRole(.headline)
                        .lineLimit(1)
                    if manifest.variants.count > 1 {
                        Text(variant.label).textRole(.monoSmall, color: .textTertiary)
                    }
                }
                Text(manifest.summary).textRole(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ModelChips(manifest: manifest, plan: library.plans[manifest.id], compact: true)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Text(Bytes.file(variant.downloadBytes)).textRole(.mono, color: .textSecondary)
                }
                FitLabel(fit: library.fits[ModelVariantKey(manifest, variant)], memoryBytes: variant.memoryBytes)
                DownloadControl(manifest: manifest, variant: variant, compact: true, onGetAccess: onGetAccess)
                    .padding(.top, 2)
            }
            .frame(width: 210, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m + 2)
        .background(isHovered ? Color.textPrimary.opacity(0.025) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show details", onOpen)
    }
}

/// License, runtime and capability chips.
struct ModelChips: View {
    let manifest: ModelManifest
    let plan: ModelsLibrary.RuntimePlan?
    var compact = false
    var showsLicense = true

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            if showsLicense { LicenseChip(license: manifest.license) }
            if let plan { RuntimeChip(plan: plan) }
            if manifest.license.gated == true { Chip("Gated", symbol: "lock", tone: .warning) }
            ForEach(capabilities, id: \.self) { Chip($0) }
            if let languages { Chip(languages, symbol: "globe") }
            if !manifest.presetVoices.isEmpty {
                Chip("\(manifest.presetVoices.count) voice\(manifest.presetVoices.count == 1 ? "" : "s")", symbol: "person.2")
            }
        }
    }

    private var capabilities: [String] {
        let c = manifest.capabilities
        var out: [String] = []
        if c.cloning { out.append("Cloning") }
        if c.voiceDesign { out.append("Voice design") }
        if c.styleInstruction { out.append("Style direction") }
        if c.expressiveTags { out.append("Expressive tags") }
        if c.nativeDialogue { out.append("Dialogue") }
        if c.wordTimestamps { out.append("Word timings") } else if c.segmentTimestamps { out.append("Timings") }
        if manifest.tasks.contains(.voiceConversion) { out.append("Voice conversion") }
        return compact ? Array(out.prefix(3)) : out
    }

    private var languages: String? {
        switch manifest.languages.count {
        case 0: nil
        case 1: manifest.languages[0].name
        default: "\(manifest.languages.count) languages"
        }
    }
}

struct LicenseChip: View {
    let license: ModelLicense
    var body: some View {
        if license.commercialUse == false {
            Chip("\(license.name) · Non-commercial", symbol: "exclamationmark.shield", tone: .danger)
        } else {
            Chip(license.name, symbol: "doc.text")
        }
    }
}

struct RuntimeChip: View {
    let plan: ModelsLibrary.RuntimePlan
    var body: some View {
        switch plan {
        case .native: Chip("Native", symbol: "bolt")
        case .python: Chip("Python helper", symbol: "shippingbox")
        case .pythonUnavailable: Chip("Python helper · needs setup", symbol: "shippingbox", tone: .warning)
        }
    }
}

/// "● Fits · 3.1 GB" — how the variant sits in this Mac's memory.
struct FitLabel: View {
    let fit: ModelsLibrary.Fit?
    let memoryBytes: Int64

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
                .glow(color, radius: 4, intensity: fit == nil ? 0 : 0.6)
            Text(label).font(.ui(11, weight: .medium)).foregroundStyle(fit == nil ? Color.textTertiary : color)
            Text("·").foregroundStyle(.textTertiary).font(.ui(11))
            Text("\(Bytes.memory(memoryBytes)) RAM").textRole(.monoSmall, color: .textTertiary)
        }
        .help(fit?.summary ?? "Peak memory while generating")
    }

    private var label: String {
        guard let fit else { return "Memory" }
        if fit.alreadyLoaded { return "Loaded" }
        switch fit.verdict {
        case .comfortable: return "Fits"
        case .tight: return "Tight fit"
        case .wontFit: return "Won't fit"
        }
    }

    private var color: Color {
        guard let fit else { return .textTertiary }
        switch fit.verdict {
        case .comfortable: return .mint
        case .tight: return .tungsten
        case .wontFit: return .velvet
        }
    }
}

/// Download state and its one action: download, progress + cancel, resume, downloaded, retry or get access.
struct DownloadControl: View {
    let manifest: ModelManifest
    let variant: ModelVariant
    var compact = false
    var onGetAccess: (String) -> Void

    @Environment(ModelDownloadCenter.self) private var downloads

    var body: some View {
        let state = downloads.state(manifest, variant)
        Group {
            switch state {
            case .unknown:
                Text("Checking…").textRole(.caption, color: .textTertiary)
                    .frame(height: Theme.ControlHeight.small)
            case .notDownloaded:
                Button("Download", systemImage: "arrow.down") { downloads.download(manifest, variant) }
                    .buttonStyle(.secondary)
            case .partial(let bytes):
                HStack(spacing: Theme.Space.s) {
                    Text("\(Bytes.file(bytes)) of \(Bytes.file(variant.downloadBytes))").textRole(.monoSmall, color: .textTertiary)
                    Button("Resume", systemImage: "arrow.clockwise") { downloads.download(manifest, variant) }
                        .buttonStyle(.secondary)
                }
            case .downloading(let p):
                progress(p)
            case .downloaded:
                StatusBadge("On this Mac", tone: .success)
                    .frame(height: Theme.ControlHeight.small)
            case .failed(let error, _):
                failed(error)
            }
        }
        .controlSize(.small)
        .stageAnimation(Theme.Motion.standard, value: stateKey(state))
    }

    private func progress(_ p: HubDownloadProgress) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: Theme.Space.s) {
                Text(p.phase == .preparing ? "Preparing…" : (p.phase == .finishing ? "Finishing…" : "\(Int((p.fractionCompleted * 100).rounded(.down)))%"))
                    .textRole(.mono, color: .tungsten)
                Spacer(minLength: 0)
                Button("Cancel download", systemImage: "xmark") { downloads.cancel(manifest, variant) }
                    .buttonStyle(.icon)
                    .labelStyle(.iconOnly)
                    .help("Cancel — the part already downloaded is kept")
            }
            ProgressBar(value: p.phase == .preparing ? nil : p.fractionCompleted)
            Text(detail(p)).textRole(.monoSmall, color: .textTertiary).lineLimit(1)
        }
        .frame(width: compact ? 190 : 260)
    }

    private func detail(_ p: HubDownloadProgress) -> String {
        guard p.phase == .downloading else { return p.totalBytes > 0 ? Bytes.file(p.totalBytes) : " " }
        var parts = ["\(Bytes.file(p.completedBytes)) of \(Bytes.file(p.totalBytes))"]
        if let bps = p.bytesPerSecond { parts.append(Bytes.rate(bps)) }
        if let eta = p.estimatedSecondsRemaining { parts.append("\(Durations.short(eta)) left") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func failed(_ error: HubError) -> some View {
        if let repo = error.gatedRepo {
            HStack(spacing: Theme.Space.s) {
                StatusBadge("Gated", tone: .warning)
                Button("Get access", systemImage: "lock.open") { onGetAccess(repo) }
                    .buttonStyle(.secondary)
            }
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Button("Retry", systemImage: "arrow.clockwise") { downloads.retry(manifest, variant) }
                    .buttonStyle(.secondary)
                Text(error.localizedDescription).textRole(.caption, color: .velvet)
                    .lineLimit(compact ? 2 : 4)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: compact ? 200 : 320, alignment: .trailing)
                    .help(error.localizedDescription)
            }
        }
    }

    private func stateKey(_ s: ModelDownloadState) -> Int {
        switch s {
        case .unknown: 0
        case .notDownloaded: 1
        case .partial: 2
        case .downloading: 3
        case .downloaded: 4
        case .failed: 5
        }
    }
}
