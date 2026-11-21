import AppKit
import EncoreCore
import SwiftUI

/// What the Models screen knows beyond the download center: which runtime each model will use, how each
/// variant fits in this Mac's memory, the Python helper's state, and the Hub's view of each repo
/// (gate, license text, access). Lives as long as the screen; snapshots inject a prepared one.
@Observable final class ModelsLibrary {
    enum RuntimePlan: Equatable {
        case native
        case python
        /// Needs the Python helper, which isn't set up (development) or missing (damaged install).
        case pythonUnavailable(String)
    }

    struct Fit: Equatable {
        var verdict: MemoryAssessment.Verdict
        var summary: String
        var alreadyLoaded = false
    }

    enum LicenseState: Equatable {
        case loading
        case loaded(HubLicenseText)
        case failed(String)
    }

    /// Where a repo's gate stands, as far as this session knows.
    enum GateState: Equatable {
        case unknown
        case checking
        case open
        case gated(kind: HubGateKind, message: String)
        /// A manual gate whose request the owner hasn't approved yet.
        case pending(message: String)
        case notFound
        case invalidToken
        case unreachable(String)
    }

    var plans: [String: RuntimePlan] = [:]
    var fits: [ModelVariantKey: Fit] = [:]
    var python: PythonRuntime.Lookup?
    var repoInfo: [String: HubRepoInfo] = [:]
    var licenses: [String: LicenseState] = [:]
    var gates: [String: GateState] = [:]
    /// Variant the user picked per model (otherwise the recommended one).
    var chosenVariant: [String: String] = [:]
    /// Fixture data: never touch the network, backends or disk.
    @ObservationIgnored var isFixture = false
    @ObservationIgnored private var backgroundPolls: [String: Task<Void, Never>] = [:]

    func variant(of manifest: ModelManifest) -> ModelVariant { manifest.variant(chosenVariant[manifest.id]) }

    // MARK: Runtime and memory

    /// Each model's runtime as the service will actually pick it (`EncoreService.plannedRuntime`, through the shared
    /// `ModelShelf`), so this screen and every model picker agree. Asking never starts the Python helper.
    func refreshPlans(catalog: ModelCatalog, shelf: ModelShelf) async {
        guard !isFixture else { return }
        python = PythonRuntime.locate()
        await shelf.refreshRuntimes(for: catalog.models)
        var plans: [String: RuntimePlan] = [:]
        for m in catalog.models { plans[m.id] = Self.plan(shelf.runtime(for: m)) }
        self.plans = plans
    }

    static func plan(_ verdict: RuntimeVerdict?) -> RuntimePlan? {
        switch verdict {
        case .runs(.mlxSwift)?: .native
        case .runs(.python)?: .python
        case .blocked(.backendNeedsSetup(_, let message))?, .blocked(.backendUnavailable(_, let message))?: .pythonUnavailable(message)
        default: nil
        }
    }

    func refreshFits(catalog: ModelCatalog, runtime: ModelRuntime) async {
        guard !isFixture else { return }
        var fits: [ModelVariantKey: Fit] = [:]
        for m in catalog.models {
            for v in m.variants {
                let a = await runtime.assess(m, v)
                fits[ModelVariantKey(m, v)] = Fit(verdict: a.verdict, summary: a.summary, alreadyLoaded: a.alreadyLoaded)
            }
        }
        self.fits = fits
    }

    // MARK: Hub details

    /// Loads repo info for every repo of the variant, and the license text, once per session.
    func loadDetails(_ manifest: ModelManifest, _ variant: ModelVariant, hub: HubService) async {
        guard !isFixture else { return }
        for repo in variant.allRepos where repoInfo[repo] == nil {
            if let info = try? await hub.repoInfo(repo) {
                repoInfo[repo] = info
                if info.gate != .none, gates[repo] == nil || gates[repo] == .unknown { await checkAccess(repo, hub: hub) }
                else if info.gate == .none { gates[repo] = .open }
            }
        }
        guard licenses[manifest.id] == nil || isFailed(licenses[manifest.id]) else { return }
        licenses[manifest.id] = .loading
        let repo = Self.licenseRepo(manifest, variant)
        do {
            let info: HubRepoInfo
            if let known = repoInfo[repo] { info = known } else { info = try await hub.repoInfo(repo) }
            repoInfo[repo] = info
            licenses[manifest.id] = .loaded(await hub.licenseText(for: info))
        } catch {
            licenses[manifest.id] = .failed(error.localizedDescription)
        }
    }

    private func isFailed(_ s: LicenseState?) -> Bool { if case .failed = s { return true } else { return false } }

    /// The repo whose license governs the weights: the manifest's license URL when it names a Hugging Face
    /// repo (often the upstream one), otherwise the variant's own repo.
    static func licenseRepo(_ manifest: ModelManifest, _ variant: ModelVariant) -> String {
        if let s = manifest.license.url, let url = URL(string: s), url.host == "huggingface.co" {
            let parts = url.path.split(separator: "/").prefix(2)
            if parts.count == 2 { return parts.joined(separator: "/") }
        }
        return variant.repo
    }

    /// Repos of the variant known (or declared) to be gated.
    func gatedRepos(_ manifest: ModelManifest, _ variant: ModelVariant) -> [String] {
        variant.allRepos.filter { repo in
            if let info = repoInfo[repo] { return info.gate != .none }
            if case .gated? = gates[repo] { return true }
            if case .pending? = gates[repo] { return true }
            return false
        }
    }

    @discardableResult
    func checkAccess(_ repo: String, hub: HubService) async -> GateState {
        guard !isFixture else { return gates[repo] ?? .unknown }
        if gates[repo] == nil || gates[repo] == .unknown { gates[repo] = .checking }
        let state: GateState
        do {
            switch try await hub.access(repo) {
            case .granted: state = .open
            case .gated(let kind, let message):
                state = Self.isPendingMessage(message) ? .pending(message: message) : .gated(kind: kind, message: message)
            case .notFoundOrPrivate: state = .notFound
            case .invalidToken: state = .invalidToken
            }
        } catch {
            state = .unreachable(error.localizedDescription)
        }
        gates[repo] = state
        return state
    }

    /// The Hub's wording when a manual request has been sent but not approved.
    static func isPendingMessage(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("awaiting") || m.contains("pending") || m.contains("under review")
    }

    /// After the gate sheet closes: keep checking for a while, and retry the download once access is granted.
    func pollAfterGate(repo: String, hub: HubService, every seconds: Double = 6, for duration: Double = 180,
                       onGranted: @escaping @MainActor () -> Void) {
        guard !isFixture else { return }
        backgroundPolls[repo]?.cancel()
        backgroundPolls[repo] = Task { [weak self] in
            let deadline = Date().addingTimeInterval(duration)
            while !Task.isCancelled, Date() < deadline {
                guard let self else { return }
                if await self.checkAccess(repo, hub: hub) == .open { onGranted(); return }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stopPolling(_ repo: String) {
        backgroundPolls[repo]?.cancel()
        backgroundPolls[repo] = nil
    }
}

extension EnvironmentValues {
    /// A prepared `ModelsLibrary` (fixtures); the screen makes its own when nil.
    @Entry var modelsLibraryOverride: ModelsLibrary? = nil
}

// MARK: - Formatting

nonisolated enum Bytes {
    static func file(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func memory(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .memory) }
    static func rate(_ bps: Double) -> String { file(Int64(bps)) + "/s" }
}

enum Durations {
    /// "12 s", "4 min", "1 h 5 min".
    static func short(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) min" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

extension ModelManifest {
    /// "Speech", "Transcription", "Voice changer".
    var group: ModelGroup {
        if tasks.contains(.tts) { return .speech }
        if tasks.contains(.stt) { return .transcription }
        return .voiceChanger
    }
    var isNonCommercial: Bool { license.commercialUse == false }
}

enum ModelGroup: String, CaseIterable, Identifiable {
    case speech, transcription, voiceChanger
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speech: "Speech"
        case .transcription: "Transcription"
        case .voiceChanger: "Voice changer"
        }
    }
    var subtitle: String {
        switch self {
        case .speech: "Text to speech, cloning and voice design"
        case .transcription: "Speech to text, with timings"
        case .voiceChanger: "Speech to speech"
        }
    }
}

/// Wraps children onto new lines when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
