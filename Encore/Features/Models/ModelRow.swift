import EncoreCore
import SwiftUI

/// One model in the catalog: its name and what it's for, a line of facts, chips only for what needs attention,
/// and on the right its download size and download state. Engineering detail lives in the details sheet.
struct ModelRow: View {
    let manifest: ModelManifest
    let library: ModelsLibrary
    var onOpen: () -> Void
    var onGetAccess: (String) -> Void

    @Environment(ModelDownloadCenter.self) private var downloads
    @State private var isHovered = false

    private var variant: ModelVariant { library.variant(of: manifest) }

    var body: some View {
        let state = downloads.state(manifest, variant)
        let facts = ModelFacts.line(manifest)
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(manifest.name).textRole(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)
                    // A gated download already says "Gated" beside its Get access button.
                    ModelAttentionChips(manifest: manifest, plan: library.plans[manifest.id],
                                        showsGated: state.error?.gatedRepo == nil)
                }
                Text(manifest.summary).textRole(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !facts.isEmpty {
                    Text(facts).textRole(.caption, color: .textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    FitNote(fit: library.fits[ModelVariantKey(manifest, variant)])
                    Text(Bytes.file(variant.downloadBytes)).textRole(.mono, color: .textSecondary)
                        .help("Download size")
                }
                DownloadControl(manifest: manifest, variant: variant, compact: true, onGetAccess: onGetAccess)
            }
            .frame(width: 196, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 10)
        .background(isHovered ? Color.textPrimary.opacity(0.025) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show details", onOpen)
    }
}

/// What a model can do, in plain words: the row's one line of facts and the details sheet's lists.
enum ModelFacts {
    /// Every capability, in a fixed order.
    static func capabilities(_ manifest: ModelManifest) -> [String] {
        let c = manifest.capabilities
        var out: [String] = []
        if c.cloning { out.append("Cloning") }
        if c.voiceDesign { out.append("Voice design") }
        if c.styleInstruction { out.append("Style direction") }
        if c.expressiveTags { out.append("Expressive tags") }
        if c.nativeDialogue { out.append("Dialogue") }
        if c.wordTimestamps { out.append("Word timings") } else if c.segmentTimestamps { out.append("Timings") }
        if manifest.tasks.contains(.voiceConversion) { out.append("Voice conversion") }
        return out
    }

    /// "English", "23 languages", or nil when the model isn't language specific.
    static func languages(_ manifest: ModelManifest) -> String? {
        switch manifest.languages.count {
        case 0: nil
        case 1: manifest.languages[0].name
        default: "\(manifest.languages.count) languages"
        }
    }

    /// "1 voice", "9 voices", or nil without built-in voices.
    static func voices(_ manifest: ModelManifest) -> String? {
        let n = manifest.presetVoices.count
        return n == 0 ? nil : "\(n) voice\(n == 1 ? "" : "s")"
    }

    /// "Cloning · Expressive tags · English · 1 voice": at most three capabilities, then how wide it is.
    static func line(_ manifest: ModelManifest) -> String {
        let parts = Array(capabilities(manifest).prefix(3)) + [languages(manifest), voices(manifest)].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

/// Chips only for what needs the user's attention: a license that restricts use, a gate, a runtime that isn't set up.
struct ModelAttentionChips: View {
    let manifest: ModelManifest
    let plan: ModelsLibrary.RuntimePlan?
    var showsGated = true

    var body: some View {
        HStack(spacing: 5) {
            if manifest.isNonCommercial {
                Chip("Non-commercial", tone: .warning)
                    .help(manifest.license.summary ?? "\(manifest.license.name): not for commercial use.")
            }
            if showsGated, manifest.license.gated == true {
                Chip("Gated", tone: .warning)
                    .help("Its authors ask you to accept their terms on Hugging Face before downloading.")
            }
            if case .pythonUnavailable? = plan {
                Chip("Needs setup", tone: .warning)
                    .help("Runs in the Python helper, which isn't set up.")
            }
        }
        .fixedSize()
    }
}

/// "Tight fit" or "Won't fit", with the numbers in a tooltip. Says nothing when the variant fits or is loaded.
struct FitNote: View {
    let fit: ModelsLibrary.Fit?

    var body: some View {
        if let fit, !fit.alreadyLoaded, fit.verdict != .comfortable {
            let wontFit = fit.verdict == .wontFit
            Text(wontFit ? "Won't fit" : "Tight fit")
                .textRole(.caption, color: (wontFit ? Tone.danger : Tone.warning).textColor)
                .lineLimit(1)
                .fixedSize()
                .help(fit.summary)
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

    /// The percentage, one bar, one line of detail.
    private func progress(_ p: HubDownloadProgress) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: Theme.Space.s) {
                Text(p.phase == .preparing ? "Preparing…" : (p.phase == .finishing ? "Finishing…" : "\(Int((p.fractionCompleted * 100).rounded(.down)))%"))
                    .textRole(.mono, color: .textPrimary)
                Spacer(minLength: 0)
                Button("Cancel download", systemImage: "xmark") { downloads.cancel(manifest, variant) }
                    .buttonStyle(.icon)
                    .labelStyle(.iconOnly)
                    .help("Cancel. The part already downloaded is kept.")
            }
            ProgressBar(value: p.phase == .preparing ? nil : p.fractionCompleted, tone: .neutral)
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
                Text(error.localizedDescription).textRole(.caption, color: .cherryInk)
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
