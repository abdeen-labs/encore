import Darwin
import Foundation
import HuggingFace

/// Presents Encore's standard Hugging Face snapshots to mlx-audio-swift without any network access.
///
/// mlx-audio-swift resolves auxiliary repos (Chatterbox's S3 tokenizer, Kokoro's G2P data, all of
/// OmniVoice) through its own downloader, which looks for a flat copy at
/// `<hub cache>/mlx-audio/<org>_<name>/` and otherwise goes to the network. Some loaders also write
/// generated files (a fast `tokenizer.json`) next to the weights. So before a load we build that flat
/// directory ourselves from the snapshot: hard links to the snapshot's blobs (no extra disk space,
/// regular files so the library's size checks pass) plus the `.mlx-audio-snapshot.json` listing the
/// library uses to decide a copy is complete.
///
/// Several Encore processes (the app, the CLI, a second app instance) can use the same directory at once, so:
/// - every change happens under one cross-process lock (`flock`, released by the OS if a process dies);
/// - each user of a directory Encore built leaves a reference file (`.encore-user-<pid>-<token>`) in it, and the
///   directory is removed only when no live process references it — never from under another process;
/// - a directory is built in a temporary folder and moved into place complete, and is checked against the
///   snapshot before every use, so the library never sees a partial copy (which would send it to the network).
/// A directory the library created itself (no marker) is used as is when it is complete, and replaced by a staged
/// one when it isn't.
enum MLXRepoStaging {
    static let markerName = ".encore-staged"
    static let manifestName = ".mlx-audio-snapshot.json"
    static let userPrefix = ".encore-user-"

    static var root: URL { HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio", isDirectory: true) }
    /// Next to huggingface_hub's own lock files; an empty file that stays (deleting a lock file others may hold is unsafe).
    static var lockFile: URL {
        HubCache.default.cacheDirectory.appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent("encore-mlx-audio-staging.lock")
    }

    static func directory(for repo: String) -> URL {
        root.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// One process's claim on a directory Encore staged; pass it back to `release`.
    struct Claim: Sendable, Hashable {
        let url: URL
        /// Nil for a directory the library made itself (nothing to release).
        let reference: String?
    }

    enum StagingError: LocalizedError {
        case incomplete(String)
        var errorDescription: String? {
            switch self {
            case .incomplete(let repo):
                "The working copy of \(repo) for the MLX engine is incomplete and another Encore process is using it. "
                    + "Quit the other Encore window or command and try again."
            }
        }
    }

    /// Returns the flat directory for `repo`, building it from `snapshot` when needed, and claims it for this process.
    static func stage(repo: String, snapshot: URL) throws -> Claim {
        try withLock {
            let fm = FileManager.default
            let target = directory(for: repo)
            let source = snapshot.resolvingSymlinksInPath()
            if fm.fileExists(atPath: target.path) {
                let complete = isComplete(target, comparedTo: source)
                if fm.fileExists(atPath: target.appendingPathComponent(markerName).path) {
                    pruneDeadUsers(in: target)
                    if complete { return Claim(url: target, reference: try addUser(to: target)) }
                    if !users(of: target).isEmpty { throw StagingError.incomplete(repo) }
                    try fm.removeItem(at: target)  // ours, unused and stale (a crash, another revision): rebuild
                } else if complete {
                    return Claim(url: target, reference: nil)
                } else {
                    try fm.removeItem(at: target)  // a partial copy the library left: it would go to the network
                }
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                var listing: [[String: Any]] = []
                try mirror(source, into: staging, relative: "", listing: &listing)
                let manifest: [String: Any] = ["revision": snapshot.lastPathComponent, "files": listing]
                try JSONSerialization.data(withJSONObject: manifest).write(to: staging.appendingPathComponent(manifestName))
                try Data().write(to: staging.appendingPathComponent(markerName))
                try fm.moveItem(at: staging, to: target)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            return Claim(url: target, reference: try addUser(to: target))
        }
    }

    /// Drops this process's claim; the directory goes once no live process uses it.
    static func release(_ claim: Claim) {
        guard let reference = claim.reference else { return }
        try? withLock {
            let fm = FileManager.default
            try? fm.removeItem(at: claim.url.appendingPathComponent(reference))
            guard fm.fileExists(atPath: claim.url.appendingPathComponent(markerName).path) else { return }
            pruneDeadUsers(in: claim.url)
            if users(of: claim.url).isEmpty { try? fm.removeItem(at: claim.url) }
            removeRootIfEmpty()
        }
    }

    /// Removes directories no live Encore process uses (left behind by a crash or a killed process).
    static func sweep() {
        try? withLock {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            for entry in entries where fm.fileExists(atPath: entry.appendingPathComponent(markerName).path) {
                pruneDeadUsers(in: entry)
                if users(of: entry).isEmpty { try? fm.removeItem(at: entry) }
            }
            removeRootIfEmpty()
        }
    }

    // MARK: Lock and users

    private static func withLock<T>(_ body: () throws -> T) throws -> T {
        let url = lockFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: url.path]) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func addUser(to directory: URL) throws -> String {
        let name = "\(userPrefix)\(getpid())-\(UUID().uuidString)"
        try Data().write(to: directory.appendingPathComponent(name))
        return name
    }

    private static func users(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(userPrefix) }
    }

    private static func pruneDeadUsers(in directory: URL) {
        for name in users(of: directory) {
            let pid = name.dropFirst(userPrefix.count).split(separator: "-").first.flatMap { pid_t($0) } ?? 0
            if pid <= 0 || !isAlive(pid) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func removeRootIfEmpty() {
        if (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Building and checking

    /// Every file of the snapshot is in `directory` at its full size (what the library's own check needs, and more).
    static func isComplete(_ directory: URL, comparedTo snapshot: URL) -> Bool {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: snapshot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return false
        }
        let base = snapshot.standardizedFileURL.path
        for case let url as URL in walker {
            let real = url.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: real.path, isDirectory: &isDirectory) else { continue }  // dangling link
            if isDirectory.boolValue { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let size = { (p: String) in (try? fm.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value }
            guard let want = size(real.path), let have = size(directory.appendingPathComponent(relative).path),
                  want == have else { return false }
        }
        return true
    }

    private static func mirror(_ source: URL, into destination: URL, relative: String, listing: inout [[String: Any]]) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: source.path) where !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            let path = relative.isEmpty ? name : "\(relative)/\(name)"
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }  // dangling link
            if isDirectory.boolValue {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
                try mirror(from, into: to, relative: path, listing: &listing)
                continue
            }
            let real = from.resolvingSymlinksInPath()
            do { try fm.linkItem(at: real, to: to) } catch { try fm.copyItem(at: real, to: to) }  // copy = APFS clone
            let size = (try? fm.attributesOfItem(atPath: real.path)[.size] as? NSNumber)?.intValue ?? 0
            listing.append(["rfilename": path, "size": size])
        }
    }
}
