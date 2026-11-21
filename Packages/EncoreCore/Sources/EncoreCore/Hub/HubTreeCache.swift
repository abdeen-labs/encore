import Foundation

/// Each repo's file list at a commit, stored the way huggingface_hub ≥ 2.4 stores it:
/// `<repo dir>/trees/<commit>.json` (`format_version` 1). Python writes and reads the same file, so
/// "is this model fully downloaded?" can be answered offline for models either side downloaded.
/// A commit's file list never changes.
public struct HubTreeCache: Sendable {
    public var layout: HubCacheLayout

    public init(layout: HubCacheLayout) { self.layout = layout }

    func url(repo: String, commit: String) -> URL {
        layout.repoDirectory(repo).appendingPathComponent("trees", isDirectory: true).appendingPathComponent(commit + ".json")
    }

    public func files(repo: String, commit: String) -> [HubRepoFile]? {
        guard let data = try? Data(contentsOf: url(repo: repo, commit: commit)) else { return nil }
        return Self.decode(data)
    }

    public func save(_ files: [HubRepoFile], repo: String, commit: String) {
        let target = url(repo: repo, commit: commit)
        guard let data = try? Self.encode(files) else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }

    static func decode(_ data: Data) -> [HubRepoFile]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format_version"] as? Int == 1, let files = json["files"] as? [String: [String: Any]] else { return nil }
        var out: [HubRepoFile] = []
        for (path, info) in files {
            guard let size = (info["size"] as? NSNumber)?.int64Value, let blobID = info["blob_id"] as? String else { return nil }
            out.append(HubRepoFile(path: path, size: (info["lfs_size"] as? NSNumber)?.int64Value ?? size, blobID: blobID,
                                   lfsSHA256: info["lfs_sha256"] as? String, xetHash: info["xet_hash"] as? String))
        }
        return out.sorted { $0.path < $1.path }
    }

    static func encode(_ files: [HubRepoFile]) throws -> Data {
        var map: [String: Any] = [:]
        for f in files {
            var info: [String: Any] = ["size": f.size, "blob_id": f.blobID]
            if let sha = f.lfsSHA256 { info["lfs_sha256"] = sha; info["lfs_size"] = f.size }
            if let xet = f.xetHash { info["xet_hash"] = xet }
            map[f.path] = info
        }
        return try JSONSerialization.data(withJSONObject: ["format_version": 1, "files": map],
                                          options: [.prettyPrinted, .sortedKeys])
    }
}

/// Advisory `flock(2)` on the same lock files huggingface_hub uses (`<hub>/.locks/<repo>/<etag>.lock`),
/// so Encore and a Python process never write the same blob at once. Works between tasks in one
/// process too, because each acquisition opens its own file description.
final class HubFileLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }
    deinit { flock(fd, LOCK_UN); close(fd) }

    /// Tries once; nil if another holder has it.
    static func tryAcquire(_ url: URL) throws -> HubFileLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw HubError.fileSystem("Couldn't open lock \(url.path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return HubFileLock(fd: fd) }
        close(fd)
        return nil
    }

    /// Waits (cancelably) until the lock is free.
    static func acquire(_ url: URL) async throws -> HubFileLock {
        while true {
            if let lock = try tryAcquire(url) { return lock }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Blocking acquisition for short synchronous critical sections.
    static func withLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw HubError.fileSystem("Couldn't open lock \(url.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw HubError.fileSystem("Couldn't lock \(url.path)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
