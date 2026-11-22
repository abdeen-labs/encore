import EncoreCore
import SwiftUI

/// What a generation screen shows while it has no model it can use: a spotlight empty state and up to three
/// starter models that download right here.
///
///     if model.needsFirstModel {
///         FirstModelStage(symbol: "theatermasks", title: "Well, hello there",
///                         message: "Encore performs with models that run on this Mac. Download one to start.",
///                         starterIDs: ["soprano", "qwen3-tts-base", "chatterbox-turbo"])
///     }
///
/// Each row downloads the variant recommended for this Mac, with progress, cancel, resume and retry. The hosting
/// screen leaves first-run by itself: when a download finishes, `ModelShelf` rescans and `needsFirstModel`
/// turns false. IDs not in the catalog are skipped. Fits 660–1100 pt of width and scrolls when short.
struct FirstModelStage: View {
    let symbol: String
    let title: String
    let message: String
    let starterIDs: [String]

    @Environment(AppDependencies.self) private var deps
    @Environment(ModelDownloadCenter.self) private var downloads
    @Environment(Router.self) private var router

    init(symbol: String, title: String, message: String, starterIDs: [String]) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.starterIDs = starterIDs
    }

    private var starters: [ModelManifest] {
        Array(starterIDs.compactMap { deps.catalog.model($0) }.prefix(3))
    }

    var body: some View {
        let starters = self.starters
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                EmptyState(symbol: symbol, title: title, message: message)
                    .padding(.bottom, -Theme.Space.l)
                if !starters.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(starters.enumerated()), id: \.element.id) { index, m in
                            if index > 0 {
                                Hairline()
                                    .padding(.horizontal, Theme.Space.l)
                            }
                            StarterRow(manifest: m) { _ in router.go(.models) }
                        }
                    }
                    .surface(.card)
                    .frame(maxWidth: 640)
                }
                Button("All models") { router.go(.models) }
                    .buttonStyle(.ghost)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .task(id: starters.map(\.id)) {
            // The download center only knows a variant's state once it has looked; ask for these few.
            for m in starters {
                let v = m.defaultVariant
                if case .unknown = downloads.state(m, v) { await downloads.refresh(m, v) }
            }
        }
    }
}

/// One starter: name, summary, size (and a license note when it matters), and the download control.
private struct StarterRow: View {
    let manifest: ModelManifest
    let onGetAccess: (String) -> Void

    /// The variant recommended for this Mac, as the Models screen picks it.
    private var variant: ModelVariant { manifest.defaultVariant }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(manifest.name).textRole(.headline).lineLimit(1)
                Text(manifest.summary).textRole(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.s) {
                    Text(Bytes.file(variant.downloadBytes)).textRole(.monoSmall, color: .textTertiary)
                        .help("Download size")
                    if manifest.license.commercialUse == false {
                        Text("Non-commercial").textRole(.caption, color: Tone.warning.textColor)
                            .help(manifest.license.summary ?? manifest.license.name)
                    }
                }
                .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DownloadControl(manifest: manifest, variant: variant, compact: true, onGetAccess: onGetAccess)
                .layoutPriority(1)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .accessibilityElement(children: .contain)
    }
}
