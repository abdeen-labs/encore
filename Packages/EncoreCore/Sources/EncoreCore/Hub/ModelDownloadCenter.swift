import Foundation
import Observation

/// Identifies one variant of one model.
public struct ModelVariantKey: Hashable, Sendable, Codable {
    public var modelID: String
    public var variantID: String
    public init(modelID: String, variantID: String) { self.modelID = modelID; self.variantID = variantID }
    public init(_ manifest: ModelManifest, _ variant: ModelVariant) { self.init(modelID: manifest.id, variantID: variant.id) }
}

/// What the models browser shows for a variant.
public enum ModelDownloadState: Sendable, Equatable {
    /// Not checked yet.
    case unknown
    case notDownloaded
    /// Some files (or partial files) are on disk; downloading resumes.
    case partial(bytesOnDisk: Int64)
    case downloading(HubDownloadProgress)
    case downloaded(bytesOnDisk: Int64)
    /// The last download failed. `.gated` errors carry the repo to open in the gate web view.
    case failed(HubError, bytesOnDisk: Int64)

    public var isDownloaded: Bool { if case .downloaded = self { return true } else { return false } }
    public var isDownloading: Bool { if case .downloading = self { return true } else { return false } }
    public var progress: HubDownloadProgress? { if case .downloading(let p) = self { return p } else { return nil } }
    public var error: HubError? { if case .failed(let e, _) = self { return e } else { return nil } }
}

/// The app's download manager: per-variant state for SwiftUI, start/cancel/retry/delete, and the
/// cache directories engines load from. One instance for the app.
@MainActor @Observable
public final class ModelDownloadCenter {
    public private(set) var states: [ModelVariantKey: ModelDownloadState] = [:]
    /// Detailed local status per variant (repos, snapshot dirs, missing files), as of the last refresh.
    public private(set) var statuses: [ModelVariantKey: HubVariantStatus] = [:]
    /// Bytes the catalog's models occupy in the Hugging Face cache.
    public private(set) var totalBytesOnDisk: Int64 = 0

    public private(set) var catalog: ModelCatalog
    public let downloader: HubDownloader
    @ObservationIgnored private var tasks: [ModelVariantKey: Task<Void, Never>] = [:]

    public init(catalog: ModelCatalog, downloader: HubDownloader = HubDownloader()) {
        self.catalog = catalog
        self.downloader = downloader
    }

    public var service: HubService { downloader.service }
    private var store: HubLocalStore { downloader.store }

    public func state(_ manifest: ModelManifest, _ variant: ModelVariant) -> ModelDownloadState {
        states[ModelVariantKey(manifest, variant)] ?? .unknown
    }

    public func updateCatalog(_ catalog: ModelCatalog) {
        self.catalog = catalog
        Task { await refresh() }
    }

    // MARK: Refresh

    /// Re-reads the cache for every variant. Fetches file lists Encore hasn't recorded (one small
    /// request per repo, once), so models downloaded outside Encore are verified too.
    public func refresh(verifyOnline: Bool = true) async {
        let pairs = catalog.models.flatMap { m in m.variants.map { (ModelVariantKey(m, $0), $0) } }
        let store = self.store, service = self.service
        let results = await Task.detached(priority: .utility) { () -> [(ModelVariantKey, HubVariantStatus)] in
            var out: [(ModelVariantKey, HubVariantStatus)] = []
            for (key, variant) in pairs {
                out.append((key, verifyOnline ? await store.status(of: variant, service: service) : store.status(of: variant)))
            }
            return out
        }.value
        for (key, status) in results { apply(status, to: key) }
        await refreshDiskUsage()
    }

    public func refresh(_ manifest: ModelManifest, _ variant: ModelVariant) async {
        let store = self.store, service = self.service
        let status = await Task.detached(priority: .utility) { await store.status(of: variant, service: service) }.value
        apply(status, to: ModelVariantKey(manifest, variant))
        await refreshDiskUsage()
    }

    private func apply(_ status: HubVariantStatus, to key: ModelVariantKey) {
        statuses[key] = status
        if tasks[key] != nil { return }  // a running download owns the state
        if case .failed(let error, _)? = states[key], status.state != .downloaded {
            states[key] = .failed(error, bytesOnDisk: status.presentBytes)
            return
        }
        states[key] = Self.state(for: status)
    }

    static func state(for status: HubVariantStatus) -> ModelDownloadState {
        switch status.state {
        case .downloaded: .downloaded(bytesOnDisk: status.presentBytes)
        case .partial: .partial(bytesOnDisk: status.presentBytes)
        case .notDownloaded: .notDownloaded
        }
    }

    private func refreshDiskUsage() async {
        let repos = Set(catalog.models.flatMap { $0.variants.flatMap(\.allRepos) })
        let store = self.store
        totalBytesOnDisk = await Task.detached(priority: .utility) { store.diskUsage(repos: repos) }.value
    }

    // MARK: Actions

    /// Starts (or resumes) a download. No-op if one is already running for this variant.
    public func download(_ manifest: ModelManifest, _ variant: ModelVariant) {
        let key = ModelVariantKey(manifest, variant)
        guard tasks[key] == nil else { return }
        states[key] = .downloading(.preparing)
        let downloader = self.downloader
        let report: @Sendable (HubDownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.tasks[key] != nil else { return }
                self.states[key] = .downloading(progress)
            }
        }
        tasks[key] = Task { [weak self] in
            var failure: HubError?
            do {
                try await downloader.download(variant, progress: report)
            } catch is CancellationError {
            } catch let error as HubError {
                failure = error
            } catch {
                failure = .fileSystem(error.localizedDescription)
            }
            guard let self else { return }
            self.tasks[key] = nil
            let status = downloader.store.status(of: variant)
            self.statuses[key] = status
            if let failure, status.state != .downloaded {
                self.states[key] = .failed(failure, bytesOnDisk: status.presentBytes)
            } else {
                self.states[key] = Self.state(for: status)
            }
            await self.refreshDiskUsage()
        }
    }

    /// Same as `download`; reads better after a failure (e.g. once a gate was accepted).
    public func retry(_ manifest: ModelManifest, _ variant: ModelVariant) { download(manifest, variant) }

    /// Stops a download, keeping partial files so it can resume.
    public func cancel(_ manifest: ModelManifest, _ variant: ModelVariant) {
        tasks[ModelVariantKey(manifest, variant)]?.cancel()
    }

    /// Deletes the variant's repos from the cache, except repos another variant that is on disk
    /// still uses (shared companions, or the same repo with different patterns). Returns bytes freed.
    @discardableResult
    public func delete(_ manifest: ModelManifest, _ variant: ModelVariant) async throws -> Int64 {
        let key = ModelVariantKey(manifest, variant)
        if let task = tasks[key] { task.cancel(); _ = await task.value }
        let inUse = Set(catalog.models.flatMap { m in
            m.variants.filter { v in
                ModelVariantKey(m, v) != key && (tasks[ModelVariantKey(m, v)] != nil || (statuses[ModelVariantKey(m, v)]?.presentBytes ?? 0) > 0)
            }.flatMap(\.allRepos)
        })
        let repos = variant.allRepos.filter { !inUse.contains($0) }
        let store = self.store
        let freed = try await Task.detached(priority: .userInitiated) { try store.delete(repos: repos) }.value
        states[key] = nil
        await refresh(manifest, variant)
        for m in catalog.models { for v in m.variants where !Set(v.allRepos).isDisjoint(with: repos) {
            await refresh(m, v)
        } }
        return freed
    }

    /// Everything an engine needs to load the variant, or nil if it isn't fully downloaded.
    public func loadContext(_ manifest: ModelManifest, _ variant: ModelVariant) -> ModelLoadContext? {
        let status = statuses[ModelVariantKey(manifest, variant)] ?? store.status(of: variant)
        guard let dirs = status.repoDirectories else { return nil }
        return ModelLoadContext(manifest: manifest, variant: variant, repoDirectories: dirs)
    }
}

/// The Hugging Face sign-in state for Settings: token in the Keychain (mirrored to the HF token
/// file), validated with whoami.
@MainActor @Observable
public final class HubAccountModel {
    public enum Status: Equatable, Sendable {
        case unknown
        case signedOut
        case checking
        case signedIn(HubAccount)
        case invalidToken
        /// Couldn't reach huggingface.co; the token is kept.
        case unreachable(String)
    }

    public private(set) var status: Status = .unknown
    public private(set) var tokenSource: HubTokenSource?
    public let tokenStore: HubTokenStore
    public let endpoint: URL

    public init(tokenStore: HubTokenStore = .standard, endpoint: URL = HubService.defaultEndpoint) {
        self.tokenStore = tokenStore
        self.endpoint = endpoint
    }

    public var account: HubAccount? { if case .signedIn(let a) = status { return a } else { return nil } }

    /// Loads the stored token (adopting an existing HF token file) and validates it.
    public func refresh() async {
        let store = tokenStore
        let current = await Task.detached { store.current() }.value
        tokenSource = current?.source
        guard let token = current?.token else { status = .signedOut; return }
        await validate(token)
    }

    /// Validates `token` with whoami and stores it only if huggingface.co accepts it.
    @discardableResult
    public func setToken(_ token: String) async -> Bool {
        guard let token = HubTokenStore.clean(token) else { signOut(); return false }
        await validate(token)
        guard case .signedIn = status else { return false }
        do {
            try tokenStore.save(token)
            tokenSource = .keychain
            return true
        } catch {
            status = .unreachable(error.localizedDescription)
            return false
        }
    }

    /// Removes the token from the Keychain and the HF token file.
    public func signOut() {
        try? tokenStore.clear()
        tokenSource = nil
        status = .signedOut
    }

    private func validate(_ token: String) async {
        status = .checking
        do {
            status = .signedIn(try await HubService(endpoint: endpoint, token: { token }).whoami(token: token))
        } catch HubError.invalidToken {
            status = .invalidToken
        } catch {
            status = .unreachable(error.localizedDescription)
        }
    }
}
