import CryptoKit
import Foundation
import os

/// Progress of one variant's download. Byte counts cover every file the variant needs; bytes that
/// were already on disk (complete or partial) count as completed from the start.
public struct HubDownloadProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        /// Checking access and listing files.
        case preparing
        case downloading
        /// Linking snapshots and verifying.
        case finishing
    }
    public var phase: Phase
    public var totalBytes: Int64
    public var completedBytes: Int64
    /// Smoothed over the last few seconds; nil until there's enough data.
    public var bytesPerSecond: Double?
    /// Files currently transferring.
    public var activeFiles: [HubFileProgress]
    public var totalFiles: Int
    public var completedFiles: Int

    public init(phase: Phase, totalBytes: Int64, completedBytes: Int64, bytesPerSecond: Double?,
                activeFiles: [HubFileProgress], totalFiles: Int, completedFiles: Int) {
        self.phase = phase; self.totalBytes = totalBytes; self.completedBytes = completedBytes
        self.bytesPerSecond = bytesPerSecond; self.activeFiles = activeFiles
        self.totalFiles = totalFiles; self.completedFiles = completedFiles
    }

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : (phase == .finishing ? 1 : 0)
    }
    public var estimatedSecondsRemaining: Double? {
        guard let bps = bytesPerSecond, bps > 0 else { return nil }
        return Double(totalBytes - completedBytes) / bps
    }

    public static let preparing = HubDownloadProgress(phase: .preparing, totalBytes: 0, completedBytes: 0, bytesPerSecond: nil,
                                                      activeFiles: [], totalFiles: 0, completedFiles: 0)
}

public struct HubFileProgress: Sendable, Hashable, Identifiable {
    public var repo: String
    public var path: String
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var id: String { repo + "/" + path }
}

/// Downloads model variants into the standard Hugging Face cache with plain HTTPS: resumable
/// (`blobs/<etag>.incomplete` + `Range`, across relaunches), every file verified against the
/// hash the Hub publishes (sha256 for LFS, git sha1 otherwise), blobs moved into place only when
/// complete and snapshot links written only after, `refs/<branch>` written last. Locks blobs with
/// the same lock files as huggingface_hub. Safe to run several downloads at once.
public final class HubDownloader: Sendable {
    public let service: HubService
    public let store: HubLocalStore
    public let maxConcurrentFiles: Int
    private let session: URLSession

    public init(service: HubService = HubService(), store: HubLocalStore = HubLocalStore(), maxConcurrentFiles: Int = 4) {
        self.service = service
        self.store = store
        self.maxConcurrentFiles = max(1, maxConcurrentFiles)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 8
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Encore.HubDownloader"
        session = URLSession(configuration: config, delegate: HubSession.RedirectGuard(), delegateQueue: queue)
    }

    deinit { session.finishTasksAndInvalidate() }

    var layout: HubCacheLayout { store.layout }

    struct Item: Sendable {
        var repo: String
        var commit: String
        var file: HubRepoFile
        /// Every path in the snapshot that points at this blob.
        var paths: [String]
        /// Bytes already in the partial blob when planning (counted as completed up front).
        var initial: Int64 = 0
    }

    /// Downloads every file `variant` needs (primary repo and companions). Returns repo id → snapshot
    /// directory. Already-complete variants return immediately without touching the network.
    /// Throws `HubError` (notably `.gated` with the repo id) or `CancellationError`; partial files
    /// are kept so the next call resumes.
    @discardableResult
    public func download(_ variant: ModelVariant,
                         progress: (@Sendable (HubDownloadProgress) -> Void)? = nil) async throws -> [String: URL] {
        if let dirs = store.status(of: variant).repoDirectories { return dirs }
        progress?(.preparing)

        // 1. Access, commit and file list for each repo.
        var items: [Item] = []
        var commits: [(repo: String, revision: String, commit: String)] = []
        for repo in variant.allRepos {
            try Task.checkCancellation()
            let revision = variant.revision(for: repo)
            switch try await service.access(repo) {
            case .granted: break
            case .gated(let kind, let message): throw HubError.gated(repo: repo, kind: kind, message: message)
            case .notFoundOrPrivate: throw HubError.repoNotFoundOrPrivate(repo: repo)
            case .invalidToken: throw HubError.invalidToken
            }
            let commit = HubCacheLayout.isCommitHash(revision) ? revision : try await service.resolveCommit(repo: repo, revision: revision)
            let all: [HubRepoFile]
            if let known = store.trees.files(repo: repo, commit: commit) { all = known } else {
                all = try await service.listFiles(repo: repo, commit: commit)
                store.trees.save(all, repo: repo, commit: commit)
            }
            let wanted = all.filter { HubGlob.matches($0.path, allow: variant.allowPatterns(for: repo)) }
            if let bad = wanted.first(where: { !HubCacheLayout.isSafeRepoPath($0.path) }) {
                throw HubError.invalidResponse("unsafe path \(bad.path) in \(repo)")
            }
            // One transfer per blob even when several paths share content.
            var byEtag: [String: Item] = [:]
            for f in wanted {
                byEtag[f.etag, default: Item(repo: repo, commit: commit, file: f, paths: [])].paths.append(f.path)
            }
            items += byEtag.values
            commits.append((repo, revision, commit))
        }

        // 2. What's already here.
        let fm = FileManager.default
        // An empty snapshots/ keeps Python's cache scanner happy while blobs are still partial.
        for c in commits { try? fm.createDirectory(at: layout.snapshotsDirectory(c.repo), withIntermediateDirectories: true) }
        var alreadyDone: Int64 = 0
        var toFetch: [Item] = []
        var needed: Int64 = 0
        for item in items {
            if HubLocalStore.regularFileSize(layout.blob(item.repo, etag: item.file.etag)) == item.file.size {
                alreadyDone += item.file.size
            } else {
                var item = item
                item.initial = min(HubLocalStore.regularFileSize(layout.incompleteBlob(item.repo, etag: item.file.etag)) ?? 0, item.file.size)
                alreadyDone += item.initial
                needed += item.file.size - item.initial
                toFetch.append(item)
            }
        }
        if let available = try? layout.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, needed > available {
            throw HubError.insufficientDiskSpace(needed: needed, available: available)
        }

        let tracker = ProgressTracker(total: items.reduce(0) { $0 + $1.file.size }, completed: alreadyDone,
                                      totalFiles: items.count, completedFiles: items.count - toFetch.count, sink: progress)
        tracker.emit(force: true)

        // 3. Fetch, biggest first, a few at a time.
        let ordered = toFetch.sorted { $0.file.size > $1.file.size }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < ordered.count else { return }
                let item = ordered[next]; next += 1
                group.addTask { try await self.fetch(item, tracker: tracker) }
            }
            for _ in 0..<min(maxConcurrentFiles, ordered.count) { addNext() }
            while try await group.next() != nil { addNext() }
        }

        // 4. Snapshot links, then refs (Python treats refs + snapshot as "present").
        tracker.setPhase(.finishing)
        for item in items {
            for path in item.paths { try link(item, path: path) }
        }
        for c in commits {
            try? fm.createDirectory(at: layout.snapshotDirectory(c.repo, commit: c.commit), withIntermediateDirectories: true)
            if !HubCacheLayout.isCommitHash(c.revision) { try writeRef(c.repo, ref: c.revision, commit: c.commit) }
        }
        tracker.emit(force: true)

        let status = store.status(of: variant)
        guard let dirs = status.repoDirectories else {
            let missing = status.repos.flatMap(\.missingFiles).prefix(3).joined(separator: ", ")
            throw HubError.fileSystem("Download finished but files are missing: \(missing)")
        }
        return dirs
    }

    // MARK: One blob

    private func fetch(_ item: Item, tracker: ProgressTracker) async throws {
        let repo = item.repo, file = item.file
        let lock = try await HubFileLock.acquire(layout.lockFile(repo, etag: file.etag))
        defer { withExtendedLifetime(lock) {} }
        let blob = layout.blob(repo, etag: file.etag)
        let incomplete = layout.incompleteBlob(repo, etag: file.etag)
        try FileManager.default.createDirectory(at: layout.blobsDirectory(repo), withIntermediateDirectories: true)

        // Someone else (another download, Python) may have finished it while we waited.
        if HubLocalStore.regularFileSize(blob) == file.size {
            tracker.fileFinished(repo: repo, path: file.path, remaining: file.size - item.initial)
            return
        }

        var attempt = 0
        var integrityRetried = false
        while true {
            try Task.checkCancellation()
            do {
                try await transfer(item, to: incomplete, tracker: tracker)
                guard rename(incomplete.path, blob.path) == 0 else {
                    throw HubError.fileSystem("Couldn't move \(file.path) into the cache: \(String(cString: strerror(errno)))")
                }
                tracker.fileFinished(repo: repo, path: file.path, remaining: 0)
                return
            } catch let error as HubError {
                if case .integrity = error, !integrityRetried {
                    integrityRetried = true
                    let had = HubLocalStore.regularFileSize(incomplete) ?? 0
                    try? FileManager.default.removeItem(at: incomplete)
                    tracker.add(-had, repo: repo, path: file.path, total: file.size)
                    continue
                }
                attempt += 1
                guard error.isTransient, attempt < 6 else { throw error }
                var delay = pow(2, Double(attempt - 1))
                if case .rateLimited(let after?) = error { delay = max(delay, after) }
                try await Task.sleep(nanoseconds: UInt64(min(delay, 30) * 1_000_000_000))
            }
        }
    }

    /// One attempt: resume `incomplete` from its current length and verify the result.
    private func transfer(_ item: Item, to incomplete: URL, tracker: ProgressTracker) async throws {
        let file = item.file
        let fm = FileManager.default
        if !fm.fileExists(atPath: incomplete.path) { fm.createFile(atPath: incomplete.path, contents: nil) }
        guard let handle = try? FileHandle(forUpdating: incomplete) else {
            throw HubError.fileSystem("Couldn't write \(incomplete.path)")
        }
        defer { try? handle.close() }

        var offset = Int64(try handle.seekToEnd())
        if offset > file.size {
            try handle.truncate(atOffset: 0)
            tracker.add(-file.size, repo: item.repo, path: file.path, total: file.size)
            offset = 0
        }
        var hasher = ContentHasher(file: file)
        if offset > 0 {
            try handle.seek(toOffset: 0)
            var read: Int64 = 0
            while read < offset {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { break }
                hasher.update(chunk); read += Int64(chunk.count)
            }
            try handle.seek(toOffset: UInt64(offset))
        }
        tracker.register(repo: item.repo, path: file.path, completed: offset, total: file.size)

        if offset < file.size {
            let url = service.url(path: HubService.resolvePath(repo: item.repo, revision: item.commit, path: file.path))
            var request = URLRequest(url: url)
            request.setValue(HubSession.userAgent, forHTTPHeaderField: "User-Agent")
            if let token = service.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let receiver = BlobReceiver(handle: handle, offset: offset, hasher: hasher, item: item, tracker: tracker)
            let task = session.dataTask(with: request)
            task.delegate = receiver
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    receiver.start(task, continuation: c)
                }
            } onCancel: {
                task.cancel()
            }
            if receiver.needsTokenCheck, service.token != nil, (try? await service.whoami()) == nil {
                throw HubError.invalidToken
            }
            hasher = receiver.finalHasher
        }
        try handle.synchronize()
        let size = Int64(try handle.seekToEnd())
        guard size == file.size, hasher.matches(file) else { throw HubError.integrity(repo: item.repo, path: file.path) }
    }

    // MARK: Links and refs

    private func link(_ item: Item, path: String) throws {
        let dest = layout.snapshotFile(item.repo, commit: item.commit, path: path)
        let target = HubCacheLayout.symlinkTarget(path: path, etag: item.file.etag)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: dest.path)) == target { return }
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        guard symlink(target, tmp.path) == 0, rename(tmp.path, dest.path) == 0 else {
            let err = String(cString: strerror(errno))
            unlink(tmp.path)
            throw HubError.fileSystem("Couldn't link \(path): \(err)")
        }
    }

    private func writeRef(_ repo: String, ref: String, commit: String) throws {
        let url = layout.refFile(repo, ref: ref)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(commit.utf8).write(to: url, options: .atomic)
        } catch { throw HubError.fileSystem("Couldn't write \(url.path): \(error.localizedDescription)") }
    }
}

// MARK: - Hashing

/// sha256 of the content for LFS files (the LFS oid), git's blob sha1 otherwise.
struct ContentHasher: Sendable {
    private var sha256: SHA256?
    private var sha1: Insecure.SHA1?

    init(file: HubRepoFile) {
        if file.isLFS { sha256 = SHA256() } else {
            var h = Insecure.SHA1()
            h.update(data: Data("blob \(file.size)\0".utf8))
            sha1 = h
        }
    }

    mutating func update(_ data: Data) {
        if sha256 != nil { sha256!.update(data: data) } else { sha1!.update(data: data) }
    }

    func hex() -> String {
        let bytes: [UInt8] = sha256.map { Array($0.finalize()) } ?? Array(sha1!.finalize())
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ file: HubRepoFile) -> Bool { hex() == file.etag.lowercased() }
}

// MARK: - Transfer delegate

/// Streams one response into the partial blob. Callbacks arrive on the session's serial queue.
private final class BlobReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var offset: Int64
    private var hasher: ContentHasher
    private let item: Item
    private let tracker: HubDownloader.ProgressTracker
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private(set) var needsTokenCheck = false
    private let lock = OSAllocatedUnfairLock()

    typealias Item = HubDownloader.Item

    init(handle: FileHandle, offset: Int64, hasher: ContentHasher, item: Item, tracker: HubDownloader.ProgressTracker) {
        self.handle = handle; self.offset = offset; self.hasher = hasher; self.item = item; self.tracker = tracker
    }

    var finalHasher: ContentHasher { lock.withLock { hasher } }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        HubSession.redirect(from: task.originalRequest, to: request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = HubError.invalidResponse("not HTTP"); return completionHandler(.cancel)
        }
        let file = item.file
        switch http.statusCode {
        case 206:
            // Content-Range: bytes <start>-<end>/<total>
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let start = range.split(separator: " ").last?.split(separator: "-").first.flatMap { Int64($0) }
            guard start == offset else {
                failure = HubError.network(code: 0, message: "Server resumed \(file.path) at the wrong offset"); return completionHandler(.cancel)
            }
        case 200:
            if offset > 0 {  // Range ignored: start over.
                do { try handle.truncate(atOffset: 0) } catch { failure = HubError.fileSystem(error.localizedDescription); return completionHandler(.cancel) }
                tracker.add(-offset, repo: item.repo, path: file.path, total: file.size)
                lock.withLock { offset = 0; hasher = ContentHasher(file: file) }
            }
        case 416:
            failure = HubError.integrity(repo: item.repo, path: file.path); return completionHandler(.cancel)
        default:
            var error = HubService.error(http, repo: item.repo, path: file.path, revision: item.commit)
                ?? HubError.http(status: http.statusCode, message: nil)
            if case .repoNotFoundOrPrivate = error { needsTokenCheck = true }
            if case .gated(let repo, nil, let message) = error { error = .gated(repo: repo, kind: nil, message: message) }
            failure = error
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = HubError.fileSystem("Couldn't write \(item.file.path): \(error.localizedDescription)")
            dataTask.cancel()
            return
        }
        lock.withLock { hasher.update(data); offset += Int64(data.count) }
        tracker.add(Int64(data.count), repo: item.repo, path: item.file.path, total: item.file.size)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Error?
        if let failure { result = failure }
        else if let urlError = error as? URLError { result = urlError.code == .cancelled ? CancellationError() : HubError.from(urlError) }
        else if let error { result = HubError.network(code: 0, message: error.localizedDescription) }
        else { result = nil }
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in defer { continuation = nil }; return continuation }
        if let result { c?.resume(throwing: result) } else { c?.resume() }
    }
}

// MARK: - Progress

extension HubDownloader {
    /// Thread-safe byte accounting, emitting at most ten snapshots a second.
    final class ProgressTracker: @unchecked Sendable {
        private struct State {
            var phase: HubDownloadProgress.Phase = .downloading
            var completed: Int64
            var completedFiles: Int
            var active: [String: HubFileProgress] = [:]
            var lastEmit: UInt64 = 0
            var samples: [(time: UInt64, bytes: Int64)] = []
        }
        private let total: Int64
        private let totalFiles: Int
        private let sink: (@Sendable (HubDownloadProgress) -> Void)?
        private let state: OSAllocatedUnfairLock<State>

        init(total: Int64, completed: Int64, totalFiles: Int, completedFiles: Int, sink: (@Sendable (HubDownloadProgress) -> Void)?) {
            self.total = total; self.totalFiles = totalFiles; self.sink = sink
            state = OSAllocatedUnfairLock(initialState: State(completed: completed, completedFiles: completedFiles))
        }

        func register(repo: String, path: String, completed: Int64, total: Int64) {
            state.withLock { $0.active[repo + "/" + path] = HubFileProgress(repo: repo, path: path, completedBytes: completed, totalBytes: total) }
        }

        func add(_ delta: Int64, repo: String, path: String, total: Int64) {
            state.withLock { s in
                s.completed += delta
                let key = repo + "/" + path
                s.active[key, default: HubFileProgress(repo: repo, path: path, completedBytes: 0, totalBytes: total)].completedBytes += delta
            }
            emit(force: false)
        }

        func fileFinished(repo: String, path: String, remaining: Int64) {
            state.withLock { s in
                s.completed += remaining
                s.completedFiles += 1
                s.active[repo + "/" + path] = nil
            }
            emit(force: false)
        }

        func setPhase(_ phase: HubDownloadProgress.Phase) {
            state.withLock { $0.phase = phase }
            emit(force: true)
        }

        func emit(force: Bool) {
            guard let sink else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let snapshot: HubDownloadProgress? = state.withLock { s in
                guard force || now - s.lastEmit >= 100_000_000 else { return nil }
                s.lastEmit = now
                s.samples.append((now, s.completed))
                s.samples.removeAll { now - $0.time > 5_000_000_000 }
                var bps: Double?
                if let first = s.samples.first, now - first.time >= 1_000_000_000 {
                    bps = max(0, Double(s.completed - first.bytes) / (Double(now - first.time) / 1e9))
                }
                return HubDownloadProgress(phase: s.phase, totalBytes: total, completedBytes: min(s.completed, total),
                                           bytesPerSecond: bps,
                                           activeFiles: s.active.values.sorted { $0.path < $1.path },
                                           totalFiles: totalFiles, completedFiles: s.completedFiles)
            }
            if let snapshot { sink(snapshot) }
        }
    }
}
