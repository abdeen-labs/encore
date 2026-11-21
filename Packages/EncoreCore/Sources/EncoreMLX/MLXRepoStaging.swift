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
/// library uses to decide a copy is complete. Directories we create carry a marker file and are
/// removed again on unload; a crash leaves them for `sweep()` at the next launch. A directory the
/// library created itself (no marker) is left alone and used as is.
enum MLXRepoStaging {
    static let markerName = ".encore-staged"
    static let manifestName = ".mlx-audio-snapshot.json"

    static var root: URL { HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio", isDirectory: true) }

    static func directory(for repo: String) -> URL {
        root.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// Returns the flat directory for `repo`, building it from `snapshot` when needed.
    /// `created` is true when Encore built it (and so should remove it later).
    static func stage(repo: String, snapshot: URL) throws -> (url: URL, created: Bool) {
        let fm = FileManager.default
        let target = directory(for: repo)
        if fm.fileExists(atPath: target.path) {
            if fm.fileExists(atPath: target.appendingPathComponent(markerName).path) {
                // Ours, possibly from a crashed run or another revision: rebuild it.
                try fm.removeItem(at: target)
            } else {
                return (target, false)
            }
        }
        let source = snapshot.resolvingSymlinksInPath()
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
        return (target, true)
    }

    static func remove(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent(markerName).path) else { return }
        try? fm.removeItem(at: url)
        removeRootIfEmpty()
    }

    private static func removeRootIfEmpty() {
        if (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Removes directories left behind by a previous run.
    static func sweep() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where fm.fileExists(atPath: entry.appendingPathComponent(markerName).path) {
            try? fm.removeItem(at: entry)
        }
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true { try? fm.removeItem(at: root) }
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
