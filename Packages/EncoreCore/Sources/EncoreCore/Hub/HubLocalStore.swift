import Foundation

extension ModelVariant {
    /// The patterns that select this variant's files in `repo` (nil = the whole repo).
    public func allowPatterns(for repo: String) -> [String]? {
        repo == self.repo ? allowPatterns : companionAllowPatterns?[repo]
    }
    /// The revision to fetch from `repo`: the pinned one for the primary repo, `main` for companions.
    public func revision(for repo: String) -> String {
        repo == self.repo ? (revision ?? "main") : "main"
    }
}

public enum HubLocalState: String, Sendable, Hashable {
    case notDownloaded, partial, downloaded
}

/// One repo of a variant, as it stands in the cache.
public struct HubRepoStatus: Sendable, Hashable {
    public var repo: String
    public var revision: String
    /// The commit `revision` resolves to locally (nil if never fully downloaded).
    public var commit: String?
    public var snapshotDirectory: URL?
    /// False when Encore doesn't know the commit's file list yet (offline, never fetched); then
    /// `isComplete` is false and the counts describe what's on disk only.
    public var isVerified: Bool
    public var isComplete: Bool
    public var requiredFiles: Int
    public var presentFiles: Int
    public var requiredBytes: Int64?
    /// Bytes of this variant's files on disk, including partial downloads.
    public var presentBytes: Int64
    /// Up to 20 missing paths, for diagnostics.
    public var missingFiles: [String]
}

public struct HubVariantStatus: Sendable, Hashable {
    public var repos: [HubRepoStatus]
    public var state: HubLocalState
    public var presentBytes: Int64 { repos.reduce(0) { $0 + $1.presentBytes } }
    public var requiredBytes: Int64? {
        repos.reduce(Int64?.some(0)) { acc, r in acc.flatMap { a in r.requiredBytes.map { a + $0 } } }
    }
    /// Repo id → snapshot directory, only when every repo is complete. Feeds `ModelLoadContext.repoDirectories`.
    public var repoDirectories: [String: URL]? {
        guard state == .downloaded else { return nil }
        return Dictionary(uniqueKeysWithValues: repos.compactMap { r in r.snapshotDirectory.map { (r.repo, $0) } })
    }
}

/// Reads and prunes the local Hugging Face cache for Encore's models.
public struct HubLocalStore: Sendable {
    public var layout: HubCacheLayout
    public var trees: HubTreeCache { HubTreeCache(layout: layout) }

    public init(layout: HubCacheLayout = HubCacheLayout()) {
        self.layout = layout
    }

    // MARK: Status

    /// Status from disk and Encore's stored file lists only (no network).
    public func status(of variant: ModelVariant) -> HubVariantStatus {
        combine(variant.allRepos.map { repoStatus($0, revision: variant.revision(for: $0), patterns: variant.allowPatterns(for: $0)) })
    }

    /// Status, fetching any file list not yet recorded in the cache's `trees/` (e.g. models
    /// downloaded by older huggingface_hub versions). Network failures leave that repo unverified.
    public func status(of variant: ModelVariant, service: HubService) async -> HubVariantStatus {
        var repos: [HubRepoStatus] = []
        for repo in variant.allRepos {
            let revision = variant.revision(for: repo)
            if let commit = layout.localCommit(repo, revision: revision), trees.files(repo: repo, commit: commit) == nil,
               FileManager.default.fileExists(atPath: layout.snapshotDirectory(repo, commit: commit).path),
               let files = try? await service.listFiles(repo: repo, commit: commit) {
                trees.save(files, repo: repo, commit: commit)
            }
            repos.append(repoStatus(repo, revision: revision, patterns: variant.allowPatterns(for: repo)))
        }
        return combine(repos)
    }

    func combine(_ repos: [HubRepoStatus]) -> HubVariantStatus {
        let state: HubLocalState
        if repos.allSatisfy(\.isComplete) { state = .downloaded }
        else if repos.contains(where: { $0.presentBytes > 0 || $0.presentFiles > 0 }) { state = .partial }
        else { state = .notDownloaded }
        return HubVariantStatus(repos: repos, state: state)
    }

    public func repoStatus(_ repo: String, revision: String, patterns: [String]?) -> HubRepoStatus {
        guard let commit = layout.localCommit(repo, revision: revision) else {
            // Never completed: only partial blobs can be here.
            return HubRepoStatus(repo: repo, revision: revision, commit: nil, snapshotDirectory: nil, isVerified: false,
                                 isComplete: false, requiredFiles: 0, presentFiles: 0, requiredBytes: nil,
                                 presentBytes: blobBytes(repo), missingFiles: [])
        }
        let snapshot = layout.snapshotDirectory(repo, commit: commit)
        guard let all = trees.files(repo: repo, commit: commit) else {
            let present = snapshotFiles(snapshot).filter { HubGlob.matches($0.path, allow: patterns) }
            return HubRepoStatus(repo: repo, revision: revision, commit: commit, snapshotDirectory: snapshot, isVerified: false,
                                 isComplete: false, requiredFiles: 0, presentFiles: present.count, requiredBytes: nil,
                                 presentBytes: present.reduce(0) { $0 + $1.size }, missingFiles: [])
        }
        let required = all.filter { HubGlob.matches($0.path, allow: patterns) }
        var presentFiles = 0
        var presentBytes: Int64 = 0
        var missing: [String] = []
        for file in required {
            switch fileState(repo, commit: commit, file: file) {
            case .linked: presentFiles += 1; presentBytes += file.size
            case .blobOnly: presentBytes += file.size; missing.append(file.path)
            case .partial(let n): presentBytes += n; missing.append(file.path)
            case .missing: missing.append(file.path)
            }
        }
        return HubRepoStatus(repo: repo, revision: revision, commit: commit, snapshotDirectory: snapshot, isVerified: true,
                             isComplete: missing.isEmpty, requiredFiles: required.count, presentFiles: presentFiles,
                             requiredBytes: required.reduce(0) { $0 + $1.size }, presentBytes: presentBytes,
                             missingFiles: Array(missing.prefix(20)))
    }

    enum FileState: Equatable { case linked, blobOnly, partial(Int64), missing }

    /// A file counts as present only when its snapshot entry resolves to a blob of the published size.
    func fileState(_ repo: String, commit: String, file: HubRepoFile) -> FileState {
        let link = layout.snapshotFile(repo, commit: commit, path: file.path)
        if Self.regularFileSize(link) == file.size { return .linked }
        if Self.regularFileSize(layout.blob(repo, etag: file.etag)) == file.size { return .blobOnly }
        if let partial = Self.regularFileSize(layout.incompleteBlob(repo, etag: file.etag)) { return .partial(min(partial, file.size)) }
        return .missing
    }

    /// Size of the regular file at `url`, following symlinks; nil if absent or not a regular file.
    static func regularFileSize(_ url: URL) -> Int64? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(st.st_size)
    }

    private func snapshotFiles(_ dir: URL) -> [(path: String, size: Int64)] {
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        var out: [(String, Int64)] = []
        for case let rel as String in e {
            if let size = Self.regularFileSize(dir.appendingPathComponent(rel)) { out.append((rel, size)) }
        }
        return out
    }

    // MARK: Sizes

    /// Bytes in a repo's `blobs/` (shared-store payloads counted through their links, partials included).
    public func blobBytes(_ repo: String) -> Int64 {
        let dir = layout.blobsDirectory(repo)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return names.reduce(0) { $0 + (Self.regularFileSize(dir.appendingPathComponent($1)) ?? 0) }
    }

    /// What deleting these repos would free, give or take shared-store payloads other repos still use.
    public func diskUsage(repos: some Sequence<String>) -> Int64 {
        Set(repos).reduce(0) { $0 + blobBytes($1) }
    }

    // MARK: Deletion

    /// Deletes whole repos from the cache: blobs, snapshots, refs and lock files, plus any
    /// shared-store payload (huggingface_hub ≥ 2.4's `<hub>/blobs/`) no other repo references.
    /// Never touches other repos. Returns bytes freed.
    @discardableResult
    public func delete(repos: some Sequence<String>) throws -> Int64 {
        var freed: Int64 = 0
        let fm = FileManager.default
        for repo in Set(repos) {
            let dir = layout.repoDirectory(repo)
            guard fm.fileExists(atPath: dir.path) else { continue }
            let shared = sharedStoreTargets(repo)
            let size = blobBytes(repo)
            do { try fm.removeItem(at: dir) } catch { throw HubError.fileSystem("Couldn't delete \(repo): \(error.localizedDescription)") }
            try? fm.removeItem(at: layout.locksDirectory(repo))
            var sharedSize: Int64 = 0
            for target in shared {
                sharedSize += Self.regularFileSize(target) ?? 0
                freed += sweepSharedBlob(target)
            }
            freed += size - sharedSize
        }
        return freed
    }

    /// Payloads in the shared store that this repo's blobs link to.
    func sharedStoreTargets(_ repo: String) -> [URL] {
        let blobs = layout.blobsDirectory(repo)
        let store = layout.root.appendingPathComponent("blobs").standardizedFileURL.path + "/"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobs.path) else { return [] }
        return names.compactMap { name in
            let link = blobs.appendingPathComponent(name)
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
            let target = URL(fileURLWithPath: dest, relativeTo: blobs).standardizedFileURL
            return target.path.hasPrefix(store) ? target : nil
        }
    }

    /// huggingface_hub's `sweep_shared_blob`: under the payload's lock, keep the payload while any
    /// manifest reference still links to it; a missing manifest is never grounds for deletion.
    func sweepSharedBlob(_ payload: URL) -> Int64 {
        let hash = payload.lastPathComponent
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return 0 }
        let manifest = payload.deletingLastPathComponent().appendingPathComponent(hash + ".refs")
        let lock = payload.deletingLastPathComponent().appendingPathComponent(hash + ".lock")
        let root = layout.root.standardizedFileURL
        return (try? HubFileLock.withLock(lock) { () -> Int64 in
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return 0 }
            var remaining: [String] = []
            for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("/") && !line.contains("..") {
                let candidate = root.appendingPathComponent(line)
                guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) else { continue }
                let target = URL(fileURLWithPath: dest, relativeTo: candidate.deletingLastPathComponent()).standardizedFileURL
                if target.path == payload.standardizedFileURL.path { remaining.append(line) }
            }
            if !remaining.isEmpty {
                let content = Set(remaining).sorted().map { $0 + "\n" }.joined()
                try? content.write(to: manifest, atomically: true, encoding: .utf8)
                return 0
            }
            let size = Self.regularFileSize(payload) ?? 0
            try? FileManager.default.removeItem(at: payload)
            try? FileManager.default.removeItem(at: manifest)
            return size
        }) ?? 0
    }
}
