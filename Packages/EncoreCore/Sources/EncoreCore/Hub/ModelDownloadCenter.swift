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
    /// Set by `showFixture`: refreshes leave the fixture states alone.
    @ObservationIgnored public private(set) var isShowingFixture = false

    /// Shows made-up states (snapshots and previews). Refreshes no longer touch the cache afterwards.
    public func showFixture(states: [ModelVariantKey: ModelDownloadState], totalBytesOnDisk: Int64) {
        isShowingFixture = true
        self.states = states
        self.totalBytesOnDisk = totalBytesOnDisk
    }

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
        guard !isShowingFixture else { return }
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
        guard !isShowingFixture else { return }
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

    /// What deleting a variant removes.
    public struct DeletionPlan: Sendable, Equatable {
        /// Repos that will be removed from the cache.
        public var repos: [String]
        /// Bytes those repos occupy now.
        public var bytes: Int64
        /// Other models that live in the same repo and so go with it.
        public var alsoRemoves: [ModelManifest]
    }

    /// Works out what `delete` would remove. The variant's own repo always goes, along with any other model
    /// stored in that same repo. A companion repo stays while a model that is still on disk needs it.
    public func deletionPlan(_ manifest: ModelManifest, _ variant: ModelVariant) -> DeletionPlan {
        let key = ModelVariantKey(manifest, variant)
        var keep: Set<String> = []
        var alsoRemoves: [ModelManifest] = []
        for m in catalog.models {
            for v in m.variants {
                let k = ModelVariantKey(m, v)
                guard k != key, isOnDisk(m, v) else { continue }
                if v.repo == variant.repo {
                    if m.id != manifest.id, !alsoRemoves.contains(where: { $0.id == m.id }) { alsoRemoves.append(m) }
                } else {
                    keep.formUnion(v.allRepos)
                }
            }
        }
        let repos = variant.allRepos.filter { !keep.contains($0) }
        return DeletionPlan(repos: repos, bytes: store.diskUsage(repos: repos), alsoRemoves: alsoRemoves)
    }

    /// Downloading, or with files of its own in the cache.
    private func isOnDisk(_ manifest: ModelManifest, _ variant: ModelVariant) -> Bool {
        let key = ModelVariantKey(manifest, variant)
        if tasks[key] != nil { return true }
        return (statuses[key] ?? store.status(of: variant)).state != .notDownloaded
    }

    /// Deletes the variant from the cache as `deletionPlan` describes. Returns bytes freed.
    @discardableResult
    public func delete(_ manifest: ModelManifest, _ variant: ModelVariant) async throws -> Int64 {
        let key = ModelVariantKey(manifest, variant)
        // Stop this download, and any download into the same repo.
        for m in catalog.models {
            for v in m.variants where v.repo == variant.repo {
                if let task = tasks[ModelVariantKey(m, v)] { task.cancel(); _ = await task.value }
            }
        }
        let repos = deletionPlan(manifest, variant).repos
        let store = self.store
        let freed = try await Task.detached(priority: .userInitiated) { try store.delete(repos: repos) }.value
        states[key] = nil
        let touched = Set(variant.allRepos)
        for m in catalog.models { for v in m.variants where !Set(v.allRepos).isDisjoint(with: touched) {
            await refresh(m, v)
        } }
        return freed
    }

    // MARK: Removing every catalog model

    /// What "delete all downloaded models" removes: every repo the catalog references (each variant's own repo and
    /// its companions) that has anything on disk, partial downloads included, plus their mlx-audio working copies.
    /// Repos in the cache that the catalog doesn't reference are never part of it.
    public struct CatalogRemovalPlan: Sendable, Equatable {
        public struct Model: Sendable, Equatable, Identifiable {
            public struct Variant: Sendable, Equatable {
                public var label: String
                /// False for a partial download.
                public var complete: Bool
                public init(label: String, complete: Bool) { self.label = label; self.complete = complete }
            }
            public var id: String
            public var name: String
            /// The variants with files on disk.
            public var variants: [Variant]
            public init(id: String, name: String, variants: [Variant]) { self.id = id; self.name = name; self.variants = variants }
        }
        /// Catalog models with a variant on disk, by name.
        public var models: [Model]
        /// Companion repos on disk that are no variant's own repo (tokenizers, codecs shared between models).
        public var sharedComponents: [String]
        /// Model repos in the cache that aren't in the catalog: left alone.
        public var otherRepos: [String]
        public var hub: HubRemovalPlan
        public var bytes: Int64 { hub.bytes }
        public var isEmpty: Bool { hub.isEmpty }

        public init(models: [Model], sharedComponents: [String], otherRepos: [String], hub: HubRemovalPlan) {
            self.models = models; self.sharedComponents = sharedComponents; self.otherRepos = otherRepos; self.hub = hub
        }
    }

    /// Measures what `removeAllCatalogModels()` would remove, from disk (no network).
    public func catalogRemovalPlan() async -> CatalogRemovalPlan {
        let catalog = self.catalog, store = self.store
        return await Task.detached(priority: .userInitiated) { Self.catalogRemovalPlan(catalog: catalog, store: store) }.value
    }

    nonisolated static func catalogRemovalPlan(catalog: ModelCatalog, store: HubLocalStore) -> CatalogRemovalPlan {
        let fm = FileManager.default
        let layout = store.layout
        let allRepos = Set(catalog.models.flatMap { $0.variants.flatMap(\.allRepos) })
        let hub = store.removalPlan(repos: allRepos)
        let touched = Set(hub.repos).union(allRepos.filter { fm.fileExists(atPath: layout.mlxAudioDirectory($0).path) })
        var models: [CatalogRemovalPlan.Model] = []
        for m in catalog.models {
            let variants = m.variants.filter { touched.contains($0.repo) }
                .map { CatalogRemovalPlan.Model.Variant(label: $0.label, complete: store.status(of: $0).state == .downloaded) }
            if !variants.isEmpty { models.append(.init(id: m.id, name: m.name, variants: variants)) }
        }
        models.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let primaries = Set(catalog.models.flatMap { $0.variants.map(\.repo) })
        let shared = touched.subtracting(primaries).sorted()
        let names = (try? fm.contentsOfDirectory(atPath: layout.root.path)) ?? []
        let others = names.compactMap(HubCacheLayout.repo(fromFolderName:)).filter { !allRepos.contains($0) }.sorted()
        return CatalogRemovalPlan(models: models, sharedComponents: shared, otherRepos: others, hub: hub)
    }

    /// Stops every download in progress (partial files stay until deleted) and waits for each to wind down.
    public func cancelAllDownloads() async {
        let running = tasks
        for task in running.values { task.cancel() }
        for task in running.values { _ = await task.value }
    }

    /// Removes every catalog model from the Hugging Face cache, as `catalogRemovalPlan()` measures it, after stopping
    /// all downloads. Unload models first: an engine may still have the files open. States refresh afterwards, so
    /// every variant reads as not downloaded.
    public func removeAllCatalogModels() async -> HubRemovalResult {
        await cancelAllDownloads()
        let catalog = self.catalog, store = self.store
        let result = await Task.detached(priority: .userInitiated) { () -> HubRemovalResult in
            store.remove(Self.catalogRemovalPlan(catalog: catalog, store: store).hub)
        }.value
        states = [:]
        await refresh(verifyOnline: false)
        return result
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

    @ObservationIgnored public private(set) var isShowingFixture = false

    /// Shows a made-up sign-in state (snapshots and previews) without reading any token.
    public func showFixture(_ status: Status, source: HubTokenSource? = nil, signedOutOfEncoreOnly: Bool = false) {
        isShowingFixture = true
        self.status = status
        tokenSource = source
        isSignedOutOfEncoreOnly = signedOutOfEncoreOnly
        sharedTokenFileExists = signedOutOfEncoreOnly
    }

    public init(tokenStore: HubTokenStore = .standard, endpoint: URL = HubService.defaultEndpoint) {
        self.tokenStore = tokenStore
        self.endpoint = endpoint
    }

    public var account: HubAccount? { if case .signedIn(let a) = status { return a } else { return nil } }

    /// True while the user is signed out of Encore only: the shared token file is ignored until they sign in again here.
    public private(set) var isSignedOutOfEncoreOnly = false
    /// Whether the shared token file exists (its contents aren't read for this). Meaningful while signed out of Encore only.
    public private(set) var sharedTokenFileExists = false

    /// Loads the token (the shared token file wins over the Keychain copy) and validates it.
    public func refresh() async {
        guard !isShowingFixture else { return }
        let store = tokenStore
        let (current, encoreOnly, fileExists) = await Task.detached {
            (store.current(), store.isSignedOutOfEncoreOnly, FileManager.default.fileExists(atPath: store.tokenFile.path))
        }.value
        tokenSource = current?.source
        isSignedOutOfEncoreOnly = encoreOnly
        sharedTokenFileExists = fileExists
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
            isSignedOutOfEncoreOnly = false
            return true
        } catch {
            status = .unreachable(error.localizedDescription)
            return false
        }
    }

    /// Signs out everywhere: removes the token from the Keychain and deletes the shared HF token file,
    /// which also signs out the `hf` tool and anything else that reads it.
    public func signOut() {
        try? tokenStore.clear()
        tokenSource = nil
        isSignedOutOfEncoreOnly = false
        sharedTokenFileExists = false
        status = .signedOut
    }

    /// Signs out of Encore only: removes Encore's Keychain copy and ignores the shared token file (which stays,
    /// so the `hf` tool stays signed in) until the user signs in again in Encore. Survives relaunches.
    /// Returns false if the Keychain refused; the status is then left as it was.
    @discardableResult
    public func signOutOfEncoreOnly() -> Bool {
        do { try tokenStore.signOutOfEncoreOnly() } catch { return false }
        tokenSource = nil
        isSignedOutOfEncoreOnly = true
        sharedTokenFileExists = FileManager.default.fileExists(atPath: tokenStore.tokenFile.path)
        status = .signedOut
        return true
    }

    /// Ends an Encore-only sign-out and signs in with the shared token file again.
    public func useSharedToken() async {
        try? tokenStore.clearEncoreOnlySignOut()
        await refresh()
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
