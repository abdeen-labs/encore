import Foundation

/// Paths in the standard Hugging Face hub cache, exactly as Python's `huggingface_hub` lays them out:
///
///     <hub>/models--org--name/blobs/<etag>
///     <hub>/models--org--name/refs/<branch>            (commit sha, no newline)
///     <hub>/models--org--name/snapshots/<sha>/<path>   → relative symlink to ../../blobs/<etag>
///     <hub>/.locks/models--org--name/<etag>.lock
public struct HubCacheLayout: Sendable, Hashable {
    public var root: URL

    /// `HF_HUB_CACHE`, else `$HF_HOME/hub`, else `~/.cache/huggingface/hub`.
    public init(root: URL = EncorePaths.huggingFaceHub) { self.root = root }

    public static func folderName(repo: String) -> String {
        "models--" + repo.replacingOccurrences(of: "/", with: "--")
    }
    /// Inverse of `folderName`; nil for anything that isn't a model repo folder.
    public static func repo(fromFolderName name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let parts = name.dropFirst("models--".count).components(separatedBy: "--")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.joined(separator: "/")
    }

    public func repoDirectory(_ repo: String) -> URL {
        root.appendingPathComponent(Self.folderName(repo: repo), isDirectory: true)
    }
    public func blobsDirectory(_ repo: String) -> URL { repoDirectory(repo).appendingPathComponent("blobs", isDirectory: true) }
    public func blob(_ repo: String, etag: String) -> URL { blobsDirectory(repo).appendingPathComponent(etag) }
    /// Partial download of a blob. Never left at the blob's final name until complete.
    public func incompleteBlob(_ repo: String, etag: String) -> URL {
        blobsDirectory(repo).appendingPathComponent(etag + ".incomplete")
    }
    public func refFile(_ repo: String, ref: String) -> URL {
        repoDirectory(repo).appendingPathComponent("refs", isDirectory: true).appendingPathComponent(ref)
    }
    public func snapshotsDirectory(_ repo: String) -> URL {
        repoDirectory(repo).appendingPathComponent("snapshots", isDirectory: true)
    }
    public func snapshotDirectory(_ repo: String, commit: String) -> URL {
        snapshotsDirectory(repo).appendingPathComponent(commit, isDirectory: true)
    }
    public func snapshotFile(_ repo: String, commit: String, path: String) -> URL {
        snapshotDirectory(repo, commit: commit).appendingPathComponent(path)
    }
    public func locksDirectory(_ repo: String) -> URL {
        root.appendingPathComponent(".locks", isDirectory: true).appendingPathComponent(Self.folderName(repo: repo), isDirectory: true)
    }
    public func lockFile(_ repo: String, etag: String) -> URL { locksDirectory(repo).appendingPathComponent(etag + ".lock") }

    /// The relative symlink target from `snapshots/<sha>/<path>` to `blobs/<etag>`.
    public static func symlinkTarget(path: String, etag: String) -> String {
        let depth = path.split(separator: "/").count - 1
        return String(repeating: "../", count: depth + 2) + "blobs/" + etag
    }

    public static func isCommitHash(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Repo-relative paths from the Hub must stay inside the snapshot directory.
    public static func isSafeRepoPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    /// The commit a revision points at locally: the revision itself when it is a sha, else `refs/<revision>`.
    public func localCommit(_ repo: String, revision: String) -> String? {
        if Self.isCommitHash(revision) { return revision }
        guard let data = try? Data(contentsOf: refFile(repo, ref: revision)),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isCommitHash(text) else { return nil }
        return text
    }
}

/// Python `huggingface_hub` pattern matching (`filter_repo_objects`): `fnmatchcase` semantics, so
/// `*` also crosses `/`, matching is case-sensitive, and a pattern ending in `/` matches everything below it.
public enum HubGlob {
    public static func filter(_ paths: [String], allow: [String]?) -> [String] {
        paths.filter { matches($0, allow: allow) }
    }

    public static func matches(_ path: String, allow: [String]?) -> Bool {
        guard let allow else { return true }
        return allow.contains { fnmatchcase(path, normalized($0)) }
    }

    static func normalized(_ pattern: String) -> String {
        let p = pattern.replacingOccurrences(of: "\\", with: "/")
        return p.hasSuffix("/") ? p + "*" : p
    }

    /// Python's `fnmatch.fnmatchcase`: `*`, `?`, `[seq]`, `[!seq]`; an unclosed `[` is literal.
    public static func fnmatchcase(_ name: String, _ pattern: String) -> Bool {
        let n = Array(name), p = Array(pattern)
        // Iterative wildcard matching with backtracking to the last `*`.
        var ni = 0, pi = 0
        var starP = -1, starN = 0
        while ni < n.count {
            if pi < p.count {
                switch p[pi] {
                case "*":
                    starP = pi; starN = ni; pi += 1; continue
                case "?":
                    ni += 1; pi += 1; continue
                case "[":
                    if let (matched, next) = matchClass(p, pi, n[ni]) {
                        if matched { ni += 1; pi = next; continue }
                    } else if n[ni] == "[" {  // unclosed: literal
                        ni += 1; pi += 1; continue
                    }
                default:
                    if p[pi] == n[ni] { ni += 1; pi += 1; continue }
                }
            }
            guard starP >= 0 else { return false }
            starN += 1; ni = starN; pi = starP + 1
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Returns (matched, index after the class) or nil if the class is unclosed.
    private static func matchClass(_ p: [Character], _ start: Int, _ c: Character) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == "!" { negate = true; i += 1 }
        var first = true
        var matched = false
        while i < p.count {
            if p[i] == "]" && !first { return (matched != negate, i + 1) }
            first = false
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                if p[i] <= c && c <= p[i + 2] { matched = true }
                i += 3
            } else {
                if p[i] == c { matched = true }
                i += 1
            }
        }
        return nil
    }
}
