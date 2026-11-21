import Foundation
import Testing
@testable import EncoreCore

// Everything here runs against temp folders, a throwaway defaults suite, a uniquely named Keychain service and a fake
// Hugging Face cache. Nothing touches the real application-support folder, defaults domain, Keychain item or cache.

// MARK: - Helpers

private let commit = String(repeating: "c", count: 40)

/// Writes a repo into a fake cache the way huggingface_hub would (blobs, snapshot links, refs, file list).
@discardableResult
private func installRepo(_ layout: HubCacheLayout, _ repo: String, files: [(path: String, content: String)]) -> [HubRepoFile] {
    let fm = FileManager.default
    var entries: [HubRepoFile] = []
    for f in files {
        let data = Data(f.content.utf8)
        var h = ContentHasher(file: HubRepoFile(path: f.path, size: Int64(data.count), blobID: ""))
        h.update(data)
        let entry = HubRepoFile(path: f.path, size: Int64(data.count), blobID: h.hex())
        entries.append(entry)
        try! fm.createDirectory(at: layout.blobsDirectory(repo), withIntermediateDirectories: true)
        try! data.write(to: layout.blob(repo, etag: entry.etag))
        let link = layout.snapshotFile(repo, commit: commit, path: f.path)
        try! fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: link.path, withDestinationPath: HubCacheLayout.symlinkTarget(path: f.path, etag: entry.etag))
    }
    try! fm.createDirectory(at: layout.refFile(repo, ref: "main").deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(commit.utf8).write(to: layout.refFile(repo, ref: "main"))
    HubTreeCache(layout: layout).save(entries, repo: repo, commit: commit)
    return entries
}

/// A blob in `repo` that links into the shared store (`<hub>/blobs/<xx>/<hash>`), recorded in the payload's manifest.
private func linkSharedPayload(_ layout: HubCacheLayout, repo: String, hash: String, content: String) throws {
    let fm = FileManager.default
    let dir = layout.root.appendingPathComponent("blobs/\(hash.prefix(2))")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let payload = dir.appendingPathComponent(hash)
    if !fm.fileExists(atPath: payload.path) { try Data(content.utf8).write(to: payload) }
    try fm.createDirectory(at: layout.blobsDirectory(repo), withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: layout.blob(repo, etag: "shared-\(hash.prefix(4))").path,
                              withDestinationPath: "../../blobs/\(hash.prefix(2))/\(hash)")
    let manifest = dir.appendingPathComponent(hash + ".refs")
    let old = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
    try (old + "\(HubCacheLayout.folderName(repo: repo))/blobs/shared-\(hash.prefix(4))\n").write(to: manifest, atomically: true, encoding: .utf8)
}

/// Apparent bytes of every regular file under `root`, each inode once: what the disk holds.
private func uniqueBytes(_ root: URL) -> Int64 {
    var seen = Set<UInt64>()
    var total: Int64 = 0
    for case let rel as String in FileManager.default.enumerator(atPath: root.path)! {
        var st = stat()
        guard lstat(root.appendingPathComponent(rel).path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              seen.insert(st.st_ino).inserted else { continue }
        total += Int64(st.st_size)
    }
    return total
}

private func manifest(_ id: String, _ variants: [(id: String, repo: String, companions: [String])]) -> ModelManifest {
    let json: [String: Any] = [
        "id": id, "name": id.capitalized, "family": id, "summary": "", "tasks": ["tts"], "engine": "x",
        "variants": variants.map { ["id": $0.id, "label": $0.id, "repo": $0.repo, "companionRepos": $0.companions,
                                    "downloadBytes": 0, "memoryBytes": 0] as [String: Any] },
        "license": ["name": "MIT"], "capabilities": [String: Any](), "languages": [Any](), "presetVoices": [Any](),
        "expressiveTags": [Any](), "parameters": [Any](), "maxChunkCharacters": 300, "sampleRate": 24000,
    ]
    return try! JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json))
}

// MARK: - App data

@MainActor @Suite struct AppDataResetTests {
    let dir: TempDir
    let support: URL, scratch: URL, caches: URL, cookies: URL, hfHome: URL
    let defaults: UserDefaults, suite: String
    let tokens: HubTokenStore
    let history: HistoryDatabase
    let voices: VoiceLibrary
    let presets: PresetStore
    let pronunciations: PronunciationStore
    let settings: AppSettings
    let reset: AppDataReset

    init() throws {
        dir = try TempDir()
        support = dir.url.appendingPathComponent("Support")
        scratch = dir.url.appendingPathComponent("Scratch")
        caches = dir.url.appendingPathComponent("Caches/dev.example.Encore")
        cookies = dir.url.appendingPathComponent("HTTPStorages/dev.example.Encore.binarycookies")
        hfHome = dir.url.appendingPathComponent("hf")
        (defaults, suite) = ThrowawayDefaults.make("EncoreResetTests")
        tokens = HubTokenStore(service: "dev.abdeen.Encore.huggingface.reset-test-\(UUID().uuidString)",
                               tokenFile: hfHome.appendingPathComponent("token"), readsEnvironment: false)
        // A temp folder stands in for the Trash, so the test can see that the reset never uses it.
        history = try HistoryDatabase(directory: support.appendingPathComponent("History"),
                                      trash: .folder(dir.url.appendingPathComponent("Trash")))
        voices = VoiceLibrary(directory: support.appendingPathComponent("Voices"))  // deletes to the Trash normally
        presets = PresetStore(directory: support)
        pronunciations = PronunciationStore(directory: support)
        settings = AppSettings(defaults: defaults)
        reset = AppDataReset(history: history, voices: voices, presets: presets, pronunciations: pronunciations,
                             settings: settings, defaults: defaults, defaultsDomain: suite, tokenStore: tokens,
                             locations: .init(applicationSupport: support, scratch: [scratch], caches: [caches, cookies]))
    }

    func seed() async throws {
        let fm = FileManager.default
        let clip = dir.url.appendingPathComponent("clip.wav")
        try Data(repeating: 7, count: 40_000).write(to: clip)
        try await voices.add(Voice(name: "Ava", origin: .cloned, transcript: "Hi.", duration: 2), referenceAudio: clip)
        try await voices.add(Voice(name: "Bram", origin: .designed, transcript: "Hello.", duration: 2), referenceAudio: clip)
        try await voices.add(Voice(name: "Cleo", origin: .imported, transcript: "Hey.", duration: 2), referenceAudio: clip)
        for i in 0..<3 {
            let id = UUID()
            let audio = history.newAudioURL(id: id)
            try Data(repeating: UInt8(i), count: 30_000).write(to: audio)
            try await history.insert(GenerationRecord(id: id, kind: .speech, title: "Take \(i)", text: "Line \(i)", modelID: "soprano",
                                                      modelName: "Soprano", voiceName: nil, voiceID: nil, parameters: [:],
                                                      audioPath: audio.path, duration: 1, sampleRate: 24000))
        }
        try presets.save(Preset(name: "Warm", modelID: "soprano", parameters: [:], post: PostProcessingOptions()))
        try pronunciations.save(PronunciationEntry(term: "Encore", replacement: "on-core"))
        try Data("damaged".utf8).write(to: support.appendingPathComponent("presets.damaged-2026.json"))
        settings.idleUnloadMinutes = 0
        settings.ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        defaults.set(Data("draft".utf8), forKey: "Studio.draft")
        try fm.createDirectory(at: scratch.appendingPathComponent("Service/Unsaved"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: scratch.appendingPathComponent("Service/Unsaved/render.wav"))
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 5000).write(to: caches.appendingPathComponent("blob"))
        try fm.createDirectory(at: cookies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cookies".utf8).write(to: cookies)
        try tokens.save("hf_resettest")  // Keychain item (test service) + the shared token file (temp)
        installRepo(HubCacheLayout(root: hfHome.appendingPathComponent("hub")), "m/kept", files: [("w.bin", "weights")])
    }

    @Test func removesEverythingListedAndKeepsModelsAndTheTokenFile() async throws {
        defer { try? tokens.clear(); ThrowawayDefaults.remove(suite) }
        try await seed()
        let fm = FileManager.default

        let inventory = await reset.inventory()
        #expect(inventory.voices == 3 && inventory.clonedVoices == 1 && inventory.designedVoices == 1 && inventory.importedVoices == 1)
        #expect(inventory.historyItems == 3 && inventory.presets == 1 && inventory.pronunciations == 1)
        #expect(inventory.hasKeychainToken && inventory.settingsKeys >= 2)
        #expect(inventory.historyBytes >= 90_000 && inventory.voiceBytes >= 120_000 && inventory.otherBytes >= 10_000)

        let report = await reset.run()
        #expect(report.failures == [])
        #expect(report.removed == inventory)
        #expect(report.bytesFreed >= 220_000)

        // Stores: empty, and what observers see.
        #expect(voices.voices.isEmpty && presets.presets.isEmpty && pronunciations.entries.isEmpty)
        #expect(try await history.count() == 0)
        #expect(settings.values == .defaults)
        // Disk: voices gone for good (the folder is empty; nothing was sent to the Trash), audio masters gone.
        #expect(try fm.contentsOfDirectory(atPath: voices.directory.path).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: history.audioDirectory.path).isEmpty)
        #expect(try Set(fm.contentsOfDirectory(atPath: support.path)) == ["History", "Voices"])
        #expect(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: caches.path).isEmpty)
        #expect(!fm.fileExists(atPath: cookies.path))
        // Defaults: the whole domain, drafts included.
        #expect(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        #expect(defaults.data(forKey: "Studio.draft") == nil)
        // Keychain item gone; the shared token file and the models stay.
        #expect(!tokens.hasKeychainToken)
        #expect(try String(contentsOf: hfHome.appendingPathComponent("token"), encoding: .utf8) == "hf_resettest")
        let kept = HubLocalStore(layout: HubCacheLayout(root: hfHome.appendingPathComponent("hub")))
        #expect(kept.repoStatus("m/kept", revision: "main", patterns: nil).isComplete)

        // Everything is usable straight away.
        let clip = dir.url.appendingPathComponent("again.wav")
        try Data(repeating: 3, count: 1000).write(to: clip)
        let v = try await voices.add(Voice(name: "New", origin: .cloned, transcript: "", duration: 1), referenceAudio: clip)
        #expect(voices.voices.map(\.id) == [v.id])
        let id = UUID()
        try Data("wav".utf8).write(to: history.newAudioURL(id: id))
        try await history.insert(GenerationRecord(id: id, kind: .speech, title: "After", text: "x", modelID: "soprano", modelName: "Soprano",
                                                  voiceName: nil, voiceID: nil, parameters: [:], audioPath: history.newAudioURL(id: id).path,
                                                  duration: 1, sampleRate: 24000))
        #expect(try await history.fetch().map(\.title) == ["After"])
        try presets.save(Preset(name: "Again", modelID: "soprano", parameters: [:], post: PostProcessingOptions()))
        #expect(PresetStore(directory: support).presets.map(\.name) == ["Again"])
        settings.idleUnloadMinutes = 30
        #expect(AppSettings(defaults: defaults).idleUnloadMinutes == 30)
    }

    /// History deletes go to the Trash, but the full reset is a wipe: audio (sidecars included) is removed for good.
    @Test func historyIsRemovedForGoodNotTrashed() async throws {
        defer { try? tokens.clear(); ThrowawayDefaults.remove(suite) }
        try await seed()
        let fm = FileManager.default
        let first = try #require(try await history.fetch().first)
        try Data("sidecar".utf8).write(to: history.audioDirectory.appendingPathComponent("\(first.id.uuidString).peaks"))

        let report = await reset.run()
        #expect(report.failures == [])
        #expect(try await history.count() == 0)
        #expect(try fm.contentsOfDirectory(atPath: history.audioDirectory.path).isEmpty)
        #expect(!fm.fileExists(atPath: dir.url.appendingPathComponent("Trash").path))

        // An ordinary delete afterwards still goes to the Trash.
        let id = UUID()
        let audio = history.newAudioURL(id: id)
        try Data("wav".utf8).write(to: audio)
        try await history.insert(GenerationRecord(id: id, kind: .speech, title: "After", text: "x", modelID: "m", modelName: "M",
                                                  voiceName: nil, voiceID: nil, parameters: [:], audioPath: audio.path,
                                                  duration: 1, sampleRate: 24000))
        try await history.delete([id])
        #expect(try fm.contentsOfDirectory(atPath: dir.url.appendingPathComponent("Trash").path) == ["\(id.uuidString).wav"])
    }

    @Test func runningTwiceIsSafe() async throws {
        defer { try? tokens.clear(); ThrowawayDefaults.remove(suite) }
        try await seed()
        _ = await reset.run()
        let second = await reset.run()
        #expect(second.failures == [])
        #expect(second.removed.voices == 0 && second.removed.historyItems == 0 && second.removed.presets == 0)
        #expect(!second.removed.hasKeychainToken && second.removed.settingsKeys == 0)
        #expect(FileManager.default.fileExists(atPath: hfHome.appendingPathComponent("token").path))
    }
}

// MARK: - Models

@MainActor @Suite struct ModelResetTests {
    let dir: TempDir
    let layout: HubCacheLayout
    let store: HubLocalStore
    // turbo (two variants) and multi share a companion; multi and changer live in the same repo.
    let turbo = manifest("turbo", [("8bit", "m/turbo-8", ["m/codec"]), ("4bit", "m/turbo-4", ["m/codec"])])
    let multi = manifest("multi", [("v3", "m/multi", ["m/codec"])])
    let changer = manifest("changer", [("v3", "m/multi", ["m/codec"])])
    let absent = manifest("absent", [("v1", "m/absent", [])])
    let keptPayload = String(repeating: "ab", count: 32)
    let sharedOnlyByTurbo = String(repeating: "cd", count: 32)

    init() throws {
        dir = try TempDir()
        layout = HubCacheLayout(root: dir.url.appendingPathComponent("hub"))
        store = HubLocalStore(layout: layout)
    }

    func seed() throws {
        let fm = FileManager.default
        let turboFiles = installRepo(layout, "m/turbo-8", files: [("model.safetensors", String(repeating: "t", count: 5000)), ("config.json", "{}")])
        installRepo(layout, "m/multi", files: [("model.safetensors", String(repeating: "m", count: 7000))])
        installRepo(layout, "m/codec", files: [("codec.safetensors", String(repeating: "c", count: 3000))])
        // A partial download: one incomplete blob, no refs yet.
        try fm.createDirectory(at: layout.blobsDirectory("m/turbo-4"), withIntermediateDirectories: true)
        try Data(repeating: 4, count: 2000).write(to: layout.incompleteBlob("m/turbo-4", etag: "abc"))
        // Not in the catalog: must survive, along with its working copy.
        installRepo(layout, "other/model", files: [("w.bin", String(repeating: "o", count: 9000))])
        try fm.createDirectory(at: layout.mlxAudioDirectory("other/model"), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 900).write(to: layout.mlxAudioDirectory("other/model").appendingPathComponent("w.bin"))
        // Shared-store payloads: one also referenced by the outside repo (stays), one only by turbo (goes).
        try linkSharedPayload(layout, repo: "m/multi", hash: keptPayload, content: String(repeating: "k", count: 11_000))
        try linkSharedPayload(layout, repo: "other/model", hash: keptPayload, content: String(repeating: "k", count: 11_000))
        try linkSharedPayload(layout, repo: "m/turbo-8", hash: sharedOnlyByTurbo, content: String(repeating: "s", count: 13_000))
        // Encore's mlx-audio working copy of turbo: hard links to its blobs (no extra space), plus a generated file.
        let copy = layout.mlxAudioDirectory("m/turbo-8")
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        for f in turboFiles { try fm.linkItem(at: layout.blob("m/turbo-8", etag: f.etag), to: copy.appendingPathComponent(f.path)) }
        try Data(repeating: 5, count: 600).write(to: copy.appendingPathComponent("tokenizer.json"))
    }

    func center() -> ModelDownloadCenter {
        ModelDownloadCenter(catalog: ModelCatalog(models: [turbo, multi, changer, absent]), downloader: HubDownloader(store: store))
    }

    @Test func planNamesWhatGoesAndCountsTrueBytes() async throws {
        try seed()
        let plan = await center().catalogRemovalPlan()
        #expect(plan.models.map(\.id) == ["changer", "multi", "turbo"])
        #expect(plan.models.first { $0.id == "turbo" }?.variants == [.init(label: "8bit", complete: true), .init(label: "4bit", complete: false)])
        #expect(plan.sharedComponents == ["m/codec"])
        #expect(plan.otherRepos == ["other/model"])
        #expect(plan.hub.repos == ["m/codec", "m/multi", "m/turbo-4", "m/turbo-8"])
        #expect(plan.hub.workingCopies.map(\.lastPathComponent) == ["m_turbo-8"])
        // Hard-linked working copy counted once; the payload the outside repo shares isn't counted; the other one is.
        let fileBytes: Int64 = 5000 + 2 + 7000 + 3000 + 2000 + 600 + 13_000
        #expect(plan.bytes > fileBytes && plan.bytes < fileBytes + 4000)  // + refs and file lists
    }

    @Test func removesCatalogReposOnlyAndReportsTrueBytes() async throws {
        try seed()
        let fm = FileManager.default
        let center = center()
        await center.refresh(verifyOnline: false)
        #expect(center.state(multi, multi.variants[0]).isDownloaded)
        let plan = await center.catalogRemovalPlan()
        let before = uniqueBytes(layout.root)

        let result = await center.removeAllCatalogModels()
        #expect(result.failures == [])
        #expect(Set(result.removedRepos) == ["m/codec", "m/multi", "m/turbo-4", "m/turbo-8"])
        #expect(result.removedWorkingCopies == 1)
        // The bytes reported are exactly what left the disk.
        let gone = before - uniqueBytes(layout.root)
        #expect(result.bytesFreed == plan.bytes)
        #expect(gone == plan.bytes, "gone \(gone), plan \(plan.bytes)")

        for repo in ["m/codec", "m/multi", "m/turbo-4", "m/turbo-8"] {
            #expect(!fm.fileExists(atPath: layout.repoDirectory(repo).path))
            #expect(!fm.fileExists(atPath: layout.locksDirectory(repo).path))
        }
        #expect(!fm.fileExists(atPath: layout.mlxAudioDirectory("m/turbo-8").path))
        // Left alone: the outside repo (still complete), its working copy, and the payload it shares.
        #expect(store.repoStatus("other/model", revision: "main", patterns: ["w.bin"]).isComplete)
        #expect(fm.fileExists(atPath: layout.mlxAudioDirectory("other/model").appendingPathComponent("w.bin").path))
        let kept = layout.root.appendingPathComponent("blobs/ab/\(keptPayload)")
        #expect(fm.fileExists(atPath: kept.path))
        #expect(try String(contentsOf: kept.appendingPathExtension("refs"), encoding: .utf8) == "models--other--model/blobs/shared-abab\n")
        #expect(!fm.fileExists(atPath: layout.root.appendingPathComponent("blobs/cd/\(sharedOnlyByTurbo)").path))

        // Every variant reads as not downloaded.
        for m in [turbo, multi, changer, absent] { for v in m.variants { #expect(center.state(m, v) == .notDownloaded) } }

        // A second run finds nothing and changes nothing.
        let again = await center.removeAllCatalogModels()
        #expect(again == HubRemovalResult())
        #expect(await center.catalogRemovalPlan().isEmpty)
        #expect(store.repoStatus("other/model", revision: "main", patterns: ["w.bin"]).isComplete)
    }
}
