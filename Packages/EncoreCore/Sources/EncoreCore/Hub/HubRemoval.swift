import Foundation

/// What removing a set of repos from the cache takes away, measured so the byte count is what the disk gets back.
public struct HubRemovalPlan: Sendable, Equatable {
    /// Repos that have a folder in the cache (complete or partly downloaded).
    public var repos: [String]
    /// mlx-audio working copies (`<hub>/mlx-audio/<org>_<name>/`) of the repos asked about.
    public var workingCopies: [URL]
    /// Bytes the disk gets back. A file that something staying still shares (a hard link elsewhere, a shared-store
    /// payload another repo references) isn't counted, and a file reached twice is counted once.
    public var bytes: Int64

    public var isEmpty: Bool { repos.isEmpty && workingCopies.isEmpty }

    public init(repos: [String], workingCopies: [URL], bytes: Int64) {
        self.repos = repos; self.workingCopies = workingCopies; self.bytes = bytes
    }
}

public struct HubRemovalResult: Sendable, Equatable {
    public var removedRepos: [String]
    public var removedWorkingCopies: Int
    /// What the disk got back (the plan's bytes less whatever is still there).
    public var bytesFreed: Int64
    /// One line per item that couldn't be removed. Everything else was removed regardless.
    public var failures: [String]

    public init(removedRepos: [String] = [], removedWorkingCopies: Int = 0, bytesFreed: Int64 = 0, failures: [String] = []) {
        self.removedRepos = removedRepos; self.removedWorkingCopies = removedWorkingCopies
        self.bytesFreed = bytesFreed; self.failures = failures
    }
}

extension HubLocalStore {
    /// Measures what removing these repos (and their mlx-audio working copies) would free. Reads the disk; no network.
    public func removalPlan(repos: some Sequence<String>) -> HubRemovalPlan {
        let fm = FileManager.default
        let wanted = Set(repos).sorted()
        let present = wanted.filter { fm.fileExists(atPath: layout.repoDirectory($0).path) }
        let copies = wanted.map { layout.mlxAudioDirectory($0) }.filter { fm.fileExists(atPath: $0.path) }
        return HubRemovalPlan(repos: present, workingCopies: copies, bytes: freeableBytes(repos: present, workingCopies: copies))
    }

    /// Removes what the plan lists: each repo through `delete(repos:)` (shared-store payloads swept only when nothing
    /// else references them), then the working copies. A failure is recorded and the rest still goes.
    public func remove(_ plan: HubRemovalPlan) -> HubRemovalResult {
        let fm = FileManager.default
        var result = HubRemovalResult()
        for repo in plan.repos {
            do {
                try delete(repos: [repo])
                result.removedRepos.append(repo)
            } catch {
                result.failures.append(error.localizedDescription)
            }
        }
        for dir in plan.workingCopies {
            do {
                if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
                result.removedWorkingCopies += 1
            } catch {
                result.failures.append("Couldn't delete \(dir.path): \(error.localizedDescription)")
            }
        }
        let mlxRoot = layout.root.appendingPathComponent("mlx-audio", isDirectory: true)
        if (try? fm.contentsOfDirectory(atPath: mlxRoot.path))?.isEmpty == true { try? fm.removeItem(at: mlxRoot) }

        let leftRepos = plan.repos.filter { fm.fileExists(atPath: layout.repoDirectory($0).path) }
        let leftCopies = plan.workingCopies.filter { fm.fileExists(atPath: $0.path) }
        let remaining = leftRepos.isEmpty && leftCopies.isEmpty ? 0 : freeableBytes(repos: leftRepos, workingCopies: leftCopies)
        result.bytesFreed = max(0, plan.bytes - remaining)
        return result
    }

    /// Bytes freed by deleting these repo folders and working copies. Regular files are counted per inode, and only
    /// when every hard link to it is inside what's being deleted (Encore's working copies hard-link the blobs).
    /// Shared-store payloads count when every repo their manifest lists is being deleted, as `sweepSharedBlob` decides.
    func freeableBytes(repos: [String], workingCopies: [URL]) -> Int64 {
        struct Inode: Hashable { var device: Int32; var number: UInt64 }
        var files: [Inode: (size: Int64, links: Int, seen: Int)] = [:]
        func note(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
            let key = Inode(device: st.st_dev, number: st.st_ino)
            var entry = files[key] ?? (Int64(st.st_size), Int(st.st_nlink), 0)
            entry.seen += 1
            files[key] = entry
        }
        func walk(_ dir: URL) {
            guard let walker = FileManager.default.enumerator(atPath: dir.path) else { return }
            for case let relative as String in walker { note(dir.appendingPathComponent(relative).path) }
        }

        let removing = Set(repos.map(HubCacheLayout.folderName(repo:)))
        var payloads = Set<URL>()
        for repo in repos {
            walk(layout.repoDirectory(repo))
            payloads.formUnion(sharedStoreTargets(repo))
        }
        for dir in workingCopies { walk(dir) }
        var manifestBytes: Int64 = 0
        for payload in payloads {
            let outcome = sharedPayloadOutcome(payload, removing: removing)
            if outcome.goes { note(payload.path) }
            manifestBytes += outcome.manifestBytesFreed
        }
        return manifestBytes + files.values.reduce(0) { $0 + ($1.seen >= $1.links ? $1.size : 0) }
    }

    /// What `sweepSharedBlob` does to this payload once the `removing` repo folders are gone: deletes it (and its
    /// manifest) when the manifest exists and every reference that still links to it belongs to one of them, or
    /// else rewrites the manifest with the remaining references.
    private func sharedPayloadOutcome(_ payload: URL, removing: Set<String>) -> (goes: Bool, manifestBytesFreed: Int64) {
        let hash = payload.lastPathComponent
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return (false, 0) }
        let manifest = payload.deletingLastPathComponent().appendingPathComponent(hash + ".refs")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return (false, 0) }
        let size = Int64(text.utf8.count)
        let root = layout.root.standardizedFileURL
        var remaining: [String] = []
        for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("/") && !line.contains("..") {
            let candidate = root.appendingPathComponent(line)
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) else { continue }
            let target = URL(fileURLWithPath: dest, relativeTo: candidate.deletingLastPathComponent()).standardizedFileURL
            guard target.path == payload.standardizedFileURL.path else { continue }
            if !removing.contains(line.split(separator: "/").first.map(String.init) ?? "") { remaining.append(line) }
        }
        if remaining.isEmpty { return (true, size) }
        return (false, max(0, size - Int64(Set(remaining).sorted().map { $0 + "\n" }.joined().utf8.count)))
    }
}
