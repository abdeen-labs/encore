import Foundation
import Observation
import Synchronization

/// The user's saved voices. One folder per voice under `directory`:
///
///     <directory>/<uuid>/voice.json        Voice metadata
///     <directory>/<uuid>/reference.<ext>   the reference clip, in whatever format it was saved
///
/// Shareable `.encorevoice` files are zip archives (made and opened with the system's `ditto`):
///
///     encorevoice.json                     {"format": "encorevoice", "version": 1, "voices": [<uuid>…]}
///     <uuid>/voice.json, <uuid>/reference.<ext>
///
/// Threading: see StoreSupport.swift. `voices` and the mutating methods are main-actor; `voice(_:)`,
/// `referenceAudioURL(for:)` and `engineVoice(for:)` are callable from any isolation.
@MainActor @Observable
public final class VoiceLibrary {
    public static let fileExtension = "encorevoice"

    /// Newest first.
    public private(set) var voices: [Voice] = []
    /// Folders that couldn't be read, with the reason. Shown so the user knows something is wrong.
    public private(set) var problems: [String] = []

    @ObservationIgnored public nonisolated let directory: URL
    @ObservationIgnored private nonisolated let deletesToTrash: Bool
    @ObservationIgnored private nonisolated let snapshot = Mutex<[UUID: Entry]>([:])

    struct Entry: Sendable { var voice: Voice; var reference: URL? }

    /// - Parameter deletesToTrash: move deleted voices to the Trash (recoverable) rather than removing them.
    public init(directory: URL = EncorePaths.voices, deletesToTrash: Bool = true) {
        self.directory = directory
        self.deletesToTrash = deletesToTrash
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    /// Re-reads every voice folder from disk.
    public func reload() {
        var entries: [UUID: Entry] = [:]
        var problems: [String] = []
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do {
                guard let voice = try StoreFiles.read(Voice.self, from: folder.appendingPathComponent("voice.json")) else { continue }
                guard folder.lastPathComponent == voice.id.uuidString else {
                    problems.append("\(folder.lastPathComponent): folder name doesn't match the voice id"); continue
                }
                entries[voice.id] = Entry(voice: voice, reference: Self.referenceFile(in: folder))
            } catch {
                problems.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        publish(entries)
        self.problems = problems
    }

    private func publish(_ entries: [UUID: Entry]) {
        snapshot.withLock { $0 = entries }
        voices = entries.values.map(\.voice).sorted { ($0.createdAt, $0.name) > ($1.createdAt, $1.name) }
    }

    private func mutate(_ body: (inout [UUID: Entry]) throws -> Void) rethrows {
        var entries = snapshot.withLock { $0 }
        try body(&entries)
        publish(entries)
    }

    // MARK: Lookups (any isolation)

    public nonisolated func voice(_ id: UUID) -> Voice? { snapshot.withLock { $0[id]?.voice } }

    public nonisolated func referenceAudioURL(for id: UUID) -> URL? { snapshot.withLock { $0[id]?.reference } }

    /// What an engine needs for a selection: `nil` for `.automatic`, the preset name, or the library voice's
    /// reference clip and transcript (transcript `nil` when empty).
    public nonisolated func engineVoice(for selection: VoiceSelection) throws -> EngineVoice? {
        switch selection {
        case .automatic: return nil
        case .preset(let name): return EngineVoice(preset: name)
        case .library(let id):
            guard let entry = snapshot.withLock({ $0[id] }) else { throw StoreError.notFound("The voice") }
            guard let ref = entry.reference else { throw StoreError.notFound("The reference audio for “\(entry.voice.name)”") }
            let transcript = entry.voice.transcript.trimmed()
            return EngineVoice(referenceAudio: ref, referenceText: transcript.isEmpty ? nil : transcript)
        }
    }

    public nonisolated func folder(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    // MARK: Browsing

    /// Every tag in use, sorted, case-insensitively unique.
    public var allTags: [String] {
        var seen = Set<String>()
        return voices.flatMap(\.tags).filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Voices matching `query` (name, tags, notes, transcript, design prompt) and carrying every tag in `tags`.
    public func search(_ query: String = "", tags: Set<String> = []) -> [Voice] {
        let q = query.trimmed()
        let wanted = Set(tags.map { $0.lowercased() })
        return voices.filter { v in
            let has = Set(v.tags.map { $0.lowercased() })
            guard wanted.isSubset(of: has) else { return false }
            guard !q.isEmpty else { return true }
            return q.split(separator: " ").allSatisfy { term in
                let t = String(term)
                return v.name.looselyContains(t) || v.tags.contains { $0.looselyContains(t) } || v.notes.looselyContains(t)
                    || v.transcript.looselyContains(t) || (v.designPrompt ?? "").looselyContains(t)
            }
        }
    }

    // MARK: Creating

    /// Saves a new voice. The reference clip is copied (or moved, for temporary files the caller is done with).
    @discardableResult
    public func add(_ voice: Voice, referenceAudio: URL, move: Bool = false) async throws -> Voice {
        var voice = voice
        voice.name = voice.name.trimmed()
        voice.tags = Self.cleanTags(voice.tags)
        if snapshot.withLock({ $0[voice.id] != nil }) { voice.id = UUID() }
        let folder = folder(for: voice.id)
        let reference = try await Self.writeVoiceFolder(voice, reference: referenceAudio, move: move, to: folder)
        mutate { $0[voice.id] = Entry(voice: voice, reference: reference) }
        return voice
    }

    private nonisolated static func writeVoiceFolder(_ voice: Voice, reference: URL, move: Bool, to folder: URL) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: reference.path) else { throw StoreError.notFound("The reference audio file") }
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let ext = reference.pathExtension.isEmpty ? "wav" : reference.pathExtension.lowercased()
            let dest = staging.appendingPathComponent("reference.\(ext)")
            if move { try fm.moveItem(at: reference, to: dest) } else { try fm.copyItem(at: reference, to: dest) }
            try StoreFiles.write(voice, to: staging.appendingPathComponent("voice.json"))
            try fm.moveItem(at: staging, to: folder)
            return folder.appendingPathComponent("reference.\(ext)")
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: Editing

    /// Saves edited metadata (name, tags, notes, transcript, language…). The id must exist.
    public func update(_ voice: Voice) throws {
        guard let existing = snapshot.withLock({ $0[voice.id] }) else { throw StoreError.notFound("The voice") }
        var voice = voice
        voice.name = voice.name.trimmed()
        voice.tags = Self.cleanTags(voice.tags)
        try StoreFiles.write(voice, to: folder(for: voice.id).appendingPathComponent("voice.json"))
        mutate { $0[voice.id] = Entry(voice: voice, reference: existing.reference) }
    }

    public func rename(_ id: UUID, to name: String) throws { try edit(id) { $0.name = name } }
    public func setTags(_ tags: [String], for id: UUID) throws { try edit(id) { $0.tags = tags } }
    public func setNotes(_ notes: String, for id: UUID) throws { try edit(id) { $0.notes = notes } }
    public func setTranscript(_ transcript: String, for id: UUID) throws { try edit(id) { $0.transcript = transcript } }

    public func edit(_ id: UUID, _ change: (inout Voice) -> Void) throws {
        guard var v = voice(id) else { throw StoreError.notFound("The voice") }
        change(&v)
        try update(v)
    }

    /// A copy with a new id, “<name> copy”, and its own copy of the reference clip.
    @discardableResult
    public func duplicate(_ id: UUID) async throws -> Voice {
        guard let entry = snapshot.withLock({ $0[id] }), let ref = entry.reference else { throw StoreError.notFound("The voice") }
        var copy = entry.voice
        copy.id = UUID()
        copy.name = uniqueName("\(entry.voice.name) copy")
        copy.createdAt = Date()
        return try await add(copy, referenceAudio: ref)
    }

    public func delete(_ id: UUID) throws {
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            if deletesToTrash, (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) != nil {
            } else {
                try FileManager.default.removeItem(at: folder)
            }
        }
        mutate { $0[id] = nil }
    }

    // MARK: Import / export

    /// Writes one `.encorevoice` file holding the given voices.
    public func export(_ ids: [UUID], to url: URL) async throws {
        let entries = try ids.map { id -> Entry in
            guard let e = snapshot.withLock({ $0[id] }), e.reference != nil else { throw StoreError.notFound("A voice to export") }
            return e
        }
        try await Self.writeArchive(entries, to: url)
    }

    private struct ArchiveManifest: Codable { var format: String; var version: Int; var voices: [UUID] }

    private nonisolated static func writeArchive(_ entries: [Entry], to url: URL) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("encorevoice-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for e in entries {
            let dir = staging.appendingPathComponent(e.voice.id.uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try StoreFiles.write(e.voice, to: dir.appendingPathComponent("voice.json"))
            if let ref = e.reference { try fm.copyItem(at: ref, to: dir.appendingPathComponent(ref.lastPathComponent)) }
        }
        try StoreFiles.write(ArchiveManifest(format: "encorevoice", version: 1, voices: entries.map(\.voice.id)),
                             to: staging.appendingPathComponent("encorevoice.json"))
        let tmpZip = fm.temporaryDirectory.appendingPathComponent("encorevoice-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tmpZip) }
        try await StoreFiles.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", staging.path, tmpZip.path])
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmpZip, to: url)
    }

    /// Adds the voices in a `.encorevoice` file. A voice whose id is already in the library gets a new id
    /// (the existing voice is never touched). Imported voices are marked `.imported`.
    @discardableResult
    public func importVoices(from url: URL) async throws -> [Voice] {
        let fm = FileManager.default
        let unpacked = fm.temporaryDirectory.appendingPathComponent("encorevoice-in-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: unpacked) }
        let found = try await Self.readArchive(url, into: unpacked)
        var imported: [Voice] = []
        for (voice, reference) in found {
            var v = voice
            v.origin = .imported
            if snapshot.withLock({ $0[v.id] != nil }) || imported.contains(where: { $0.id == v.id }) { v.id = UUID() }
            imported.append(try await add(v, referenceAudio: reference))
        }
        return imported
    }

    /// Limits for untrusted archives: voice files hold a few short clips, so anything far bigger is refused.
    nonisolated static let maxArchiveEntries = 2_000
    nonisolated static let maxArchiveBytes: Int64 = 1 << 30

    /// Unpacks and validates an untrusted `.encorevoice` file. Before extraction the listing is checked for
    /// absolute paths, `..` components, symbolic links and excessive size; after extraction every item must be
    /// a plain file or directory inside `dir`. Only `voice.json` and a `reference.<ext>` file per voice are
    /// used, and the caller copies those two files into the library.
    nonisolated static func readArchive(_ url: URL, into dir: URL) async throws -> [(Voice, URL)] {
        let fm = FileManager.default
        let name = url.lastPathComponent
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try await checkListing(of: url)
            try await StoreFiles.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path])
        } catch let error as StoreError {
            if case .invalidFile = error { throw error }
            throw StoreError.invalidFile("“\(name)” isn't a voice file Encore can open.")
        } catch {
            throw StoreError.invalidFile("“\(name)” isn't a voice file Encore can open.")
        }
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        func inside(_ u: URL) -> Bool { u.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") }

        try checkExtracted(dir, root: root, archiveName: name)

        let manifestURL = dir.appendingPathComponent("encorevoice.json")
        guard inside(manifestURL), let manifest = try? StoreFiles.read(ArchiveManifest.self, from: manifestURL),
              manifest.format == "encorevoice" else {
            throw StoreError.invalidFile("“\(name)” isn't an Encore voice file.")
        }
        guard manifest.version <= 1 else {
            throw StoreError.invalidFile("“\(name)” was made by a newer version of Encore.")
        }
        var out: [(Voice, URL)] = []
        for id in manifest.voices {
            // Folder names come from parsed UUIDs, file names from a fixed pattern: nothing from the archive becomes a path.
            let folder = dir.appendingPathComponent(id.uuidString, isDirectory: true)
            let meta = folder.appendingPathComponent("voice.json")
            guard inside(folder), inside(meta), isPlainFile(meta),
                  let voice = try? StoreFiles.read(Voice.self, from: meta),
                  let ref = referenceFile(in: folder), inside(ref), isPlainFile(ref) else {
                throw StoreError.invalidFile("A voice in “\(name)” is incomplete.")
            }
            out.append((voice, ref))
        }
        if out.isEmpty { throw StoreError.invalidFile("“\(name)” contains no voices.") }
        return out
    }

    /// Everything extracted must be a regular file or directory (no links, devices, fifos) inside `root`, within the limits.
    private nonisolated static func checkExtracted(_ dir: URL, root: String, archiveName name: String) throws {
        var count = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let items = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [])?.allObjects ?? []
        for case let item as URL in items {
            let v = try item.resourceValues(forKeys: Set(keys))
            count += 1
            bytes += Int64(v.fileSize ?? 0)
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard v.isSymbolicLink != true, v.isRegularFile == true || v.isDirectory == true, resolved.hasPrefix(root + "/") else {
                throw StoreError.invalidFile("“\(name)” contains links or special files and wasn't imported.")
            }
            guard count <= maxArchiveEntries, bytes <= maxArchiveBytes else {
                throw StoreError.invalidFile("“\(name)” is too large to be a voice file.")
            }
        }
    }

    /// Refuses archives whose listing has absolute paths, `..`, symbolic links, too many entries or too many bytes.
    private nonisolated static func checkListing(of url: URL) async throws {
        let unsafe = StoreError.invalidFile("“\(url.lastPathComponent)” contains unsafe paths and wasn't imported.")
        let names = try await StoreFiles.output("/usr/bin/zipinfo", ["-1", url.path]).split(separator: "\n", omittingEmptySubsequences: true)
        guard names.count <= maxArchiveEntries else { throw StoreError.invalidFile("“\(url.lastPathComponent)” is too large to be a voice file.") }
        for entry in names {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || entry.hasPrefix("\\") || entry.contains("\\") || parts.contains("..") || entry.contains(":") {
                throw unsafe
            }
        }
        // Long listing: the first column is the Unix mode for archives made on Unix; "l" marks a symbolic link.
        // The last line holds the uncompressed total.
        let long = try await StoreFiles.output("/usr/bin/zipinfo", [url.path])
        for line in long.split(separator: "\n") {
            let mode = line.prefix { !$0.isWhitespace }
            if mode.count == 10, mode.first == "l" { throw unsafe }
            if mode.count == 10, let f = mode.first, !"-d".contains(f) { throw unsafe }
        }
        if let total = long.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression) {
            let digits = long[total].prefix { $0.isNumber }
            if let n = Int64(digits), n > maxArchiveBytes {
                throw StoreError.invalidFile("“\(url.lastPathComponent)” is too large to be a voice file.")
            }
        }
    }

    private nonisolated static func isPlainFile(_ u: URL) -> Bool {
        guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return v.isRegularFile == true && v.isSymbolicLink != true
    }

    // MARK: Helpers

    /// `reference.<ext>` in a voice folder, where `<ext>` is 1–8 letters/digits (a plain file name, never a path).
    nonisolated static func referenceFile(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        return files.filter { $0.lastPathComponent.range(of: #"^reference\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil }
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.collapsingWhitespace() }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(voices.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
