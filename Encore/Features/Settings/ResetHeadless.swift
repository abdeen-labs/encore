#if DEBUG
import EncoreCore
import Foundation

/// DEBUG only: proves Settings → Reset inside the app process, through the same calls the confirmation sheets make
/// (`AppDependencies.resetAppData()` and `removeAllModels()`), with no window and no audio:
///
///     Encore.app/Contents/MacOS/Encore --reset-headless [--keep]
///
/// Everything it touches is throwaway: it sets `HF_HOME` to a temporary folder before anything reads it, builds
/// `AppDependencies(isolatedRoot:)` (stores in that folder, a throwaway defaults suite, its own Keychain service name),
/// and refuses to start unless every place a reset deletes from is inside those. It seeds voices, history, presets,
/// pronunciations, settings, a Studio draft, a Keychain token and a fake model cache (catalog models, a shared
/// companion, two models sharing one repo, an mlx-audio working copy, and a repo that isn't Encore's), runs each reset,
/// and checks the stores are empty and usable and the model shelf shows nothing downloaded. Exit status 0 when all hold.
@MainActor
enum ResetHeadless {
    static var isRequested: Bool { CommandLine.arguments.contains("--reset-headless") }

    static func run() -> Never {
        Task { @MainActor in exit(await go()) }
        dispatchMain()
    }

    private static let start = Date()
    private static var failures: [String] = []

    private static func log(_ s: String) {
        print(String(format: "[%7.2f] ", Date().timeIntervalSince(start)) + s)
        fflush(stdout)
    }

    private static func check(_ ok: Bool, _ what: String) {
        log((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures.append(what) }
    }

    private static func inside(_ url: URL, _ root: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }

    static func go() async -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("EncoreResetHeadless-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if !CommandLine.arguments.contains("--keep") { try? fm.removeItem(at: root) } }

        // Every Hugging Face path into the temp folder, before anything reads them.
        let hfHome = root.appendingPathComponent("hf")
        setenv("HF_HOME", hfHome.path, 1)
        for name in ["HF_HUB_CACHE", "HF_TOKEN_PATH", "HF_TOKEN", "XDG_CACHE_HOME"] { unsetenv(name) }
        setenv("HF_HUB_OFFLINE", "1", 1)
        log("temp root: \(root.path)")

        let deps = AppDependencies(isolatedRoot: root)
        let reset = deps.appDataReset
        let hub = deps.downloads.downloader.store.layout

        // Refuse to go on unless every destructive target is throwaway.
        let safe: [(Bool, String)] = [
            (inside(reset.locations.applicationSupport, root), "application support is in the temp root"),
            (reset.locations.scratch.allSatisfy { inside($0, root) }, "scratch folders are in the temp root"),
            (reset.locations.caches.allSatisfy { inside($0, root) }, "cache folders are in the temp root"),
            (inside(reset.history.directory, root) && inside(reset.voices.directory, root), "history and voices are in the temp root"),
            (inside(hub.root, root) && inside(EncorePaths.huggingFaceHub, root), "the model cache is in the temp root"),
            (inside(reset.tokenStore.tokenFile, root), "the token file is in the temp root"),
            (reset.tokenStore.service != HubTokenStore.defaultService, "the Keychain service is a test one (\(reset.tokenStore.service))"),
            (reset.defaultsDomain.hasPrefix(fm.temporaryDirectory.path) && reset.defaultsDomain != Bundle.main.bundleIdentifier,
             "the defaults domain is a throwaway suite"),
            (!deps.clearsSystemStorage, "system URL cache, cookies and web data are left alone"),
        ]
        for (ok, what) in safe { check(ok, "safety: " + what) }
        guard failures.isEmpty else { log("refusing to run: a target is outside the temp root"); return 2 }

        do { try await seed(deps, root: root) } catch { log("FAIL seed: \(error)"); return 1 }
        await proveAppDataReset(deps)
        await proveModelReset(deps)

        try? reset.tokenStore.clear()  // the test Keychain item and the temp token file
        log(failures.isEmpty ? "ALL OK" : "FAILURES: \(failures.count)\n  " + failures.joined(separator: "\n  "))
        return failures.isEmpty ? 0 : 1
    }

    // MARK: Seed

    static let otherRepo = "someone-else/their-model"

    private static func seed(_ deps: AppDependencies, root: URL) async throws {
        let clip = root.appendingPathComponent("seed.wav")
        let rate = 24_000.0
        let tone = (0..<Int(rate * 1.5)).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
        try AudioExporter.writeWAV(AudioBuffer(samples: tone, sampleRate: rate), to: clip)

        for (name, origin) in [("Ava", Voice.Origin.cloned), ("Bram", .designed), ("Cleo", .imported)] {
            try await deps.voices.add(Voice(name: name, origin: origin, transcript: "A line.", duration: 1.5), referenceAudio: clip)
        }
        let db = deps.service.history
        for i in 1...3 {
            let id = UUID()
            let audio = db.newAudioURL(id: id)
            try FileManager.default.copyItem(at: clip, to: audio)
            try await db.insert(GenerationRecord(id: id, kind: .speech, title: "Take \(i)", text: "Line \(i)", modelID: "soprano",
                                                 modelName: "Soprano", audioPath: audio.path, duration: 1.5, sampleRate: rate))
        }
        try await db.insert(TranscriptionRecord(sourceName: "talk.wav", sourcePath: clip.path, modelID: "whisper-large-v3-turbo",
                                                modelName: "Whisper", transcript: Transcript(text: "A line.", language: "en", duration: 1.5,
                                                                                             segments: [])))
        try deps.presets.save(Preset(name: "Warm", modelID: "soprano", parameters: ["temperature": .double(0.2)], post: PostProcessingOptions()))
        try deps.presets.save(Preset(name: "Bright", modelID: "soprano", parameters: ["temperature": .double(0.5)], post: PostProcessingOptions()))
        try deps.pronunciations.save(PronunciationEntry(term: "Encore", replacement: "on-core"))
        try deps.pronunciations.save(PronunciationEntry(term: "MLX", replacement: "M L X"))
        deps.settings.idleUnloadMinutes = 0
        deps.settings.defaultExportFormat = .m4a
        deps.settings.noteModelUsed("soprano", for: .speech)
        let studio = deps.screenModel("Studio") { StudioModel(deps: deps) }
        studio.script = "A draft that should not survive."
        try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("Scratch/leftover.wav"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: root.appendingPathComponent("Caches/cached"))
        try deps.appDataReset.tokenStore.save("hf_headless_not_a_real_token")
        await deps.hubAccount.refresh()

        // A fake model cache: Soprano (plus a working copy), Chatterbox Multilingual's repo (two catalog models share it)
        // with its companion, and a repo that isn't in Encore's catalog.
        let layout = deps.downloads.downloader.store.layout
        let soprano = deps.catalog.model("soprano")!.defaultVariant
        let multi = deps.catalog.model("chatterbox-multilingual")!.defaultVariant
        let repos = soprano.allRepos + multi.allRepos + [otherRepo]
        for (n, repo) in repos.enumerated() {
            try install(layout, repo: repo, files: [("config.json", 200 + n), ("model.safetensors", 300_000 + 1000 * n)])
        }
        let copy = layout.mlxAudioDirectory(soprano.repo)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let snapshot = layout.snapshotDirectory(soprano.repo, commit: commit)
        for name in ["config.json", "model.safetensors"] {
            try FileManager.default.linkItem(at: snapshot.appendingPathComponent(name).resolvingSymlinksInPath(), to: copy.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: layout.mlxAudioDirectory(otherRepo), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 5000).write(to: layout.mlxAudioDirectory(otherRepo).appendingPathComponent("w.bin"))
        await deps.downloads.refresh(verifyOnline: false)
        deps.modelShelf.rescan()
        await deps.modelShelf.waitForScan()
        log("seeded: \(deps.voices.voices.count) voices, \((try? await db.count()) ?? -1) history items, \(deps.presets.presets.count) presets, "
            + "\(deps.pronunciations.entries.count) pronunciations; shelf: \(deps.modelShelf.downloaded.map(\.modelID).sorted())")
    }

    private static let commit = String(repeating: "e", count: 40)

    /// One repo in the standard cache layout, with its file list, so Encore reads it as fully downloaded.
    private static func install(_ layout: HubCacheLayout, repo: String, files: [(String, Int)]) throws {
        let fm = FileManager.default
        var entries: [HubRepoFile] = []
        for (path, size) in files {
            let blobID = String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(40))
            let file = HubRepoFile(path: path, size: Int64(size), blobID: blobID)
            entries.append(file)
            try fm.createDirectory(at: layout.blobsDirectory(repo), withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: layout.blob(repo, etag: file.etag))
            let link = layout.snapshotFile(repo, commit: commit, path: path)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: HubCacheLayout.symlinkTarget(path: path, etag: file.etag))
        }
        try fm.createDirectory(at: layout.refFile(repo, ref: "main").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(commit.utf8).write(to: layout.refFile(repo, ref: "main"))
        HubTreeCache(layout: layout).save(entries, repo: repo, commit: commit)
    }

    // MARK: Delete all app data

    private static func proveAppDataReset(_ deps: AppDependencies) async {
        log("— Delete all app data —")
        let reset = deps.appDataReset
        let shelfBefore = deps.modelShelf.downloaded
        let inventory = await reset.inventory()
        log("sheet would show: \(inventory.voices) voices (\(inventory.clonedVoices) cloned, \(inventory.designedVoices) designed, "
            + "\(inventory.importedVoices) imported), \(inventory.historyItems) history items, \(inventory.presets) presets, "
            + "\(inventory.pronunciations) pronunciations, \(inventory.settingsKeys) defaults keys, keychain token: \(inventory.hasKeychainToken), "
            + "\(inventory.totalBytes) bytes")
        check(inventory.voices == 3 && inventory.historyItems == 4 && inventory.presets == 2 && inventory.pronunciations == 2,
              "inventory counts what was seeded")
        check(inventory.hasKeychainToken && inventory.settingsKeys >= 2, "inventory sees the Keychain token and the settings and draft")
        check(deps.screenModels["Studio"] != nil, "a Studio screen model with a draft exists before")

        let report: AppDataReset.Report
        do { report = try await deps.resetAppData() } catch { check(false, "resetAppData threw \(error)"); return }
        log("report: freed \(report.bytesFreed) bytes, failures \(report.failures)")
        check(report.failures.isEmpty, "no failures")
        check(report.removed == inventory, "the report lists what was there")

        check(deps.voices.voices.isEmpty && ((try? FileManager.default.contentsOfDirectory(atPath: deps.voices.directory.path)) ?? ["x"]).isEmpty,
              "voice library empty, its folder empty (removed, not trashed)")
        check(((try? await deps.service.history.count()) ?? -1) == 0, "history database empty")
        check(((try? FileManager.default.contentsOfDirectory(atPath: deps.service.history.audioDirectory.path)) ?? ["x"]).isEmpty, "audio masters gone")
        for _ in 0..<100 where !deps.history.items.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        check(deps.history.items.isEmpty && deps.history.totalCount == 0, "HistoryStore (what the screen shows) is empty")
        check(deps.presets.presets.isEmpty && deps.pronunciations.entries.isEmpty, "presets and pronunciations empty")
        check(deps.settings.values == .defaults, "settings back to defaults")
        check((reset.defaults.persistentDomain(forName: reset.defaultsDomain) ?? [:]).isEmpty, "defaults domain empty (drafts included)")
        check(Array(deps.screenModels.keys) == [AppDependencies.modelShelfKey], "kept screen models dropped (only the model shelf stays)")
        check(deps.hubAccount.tokenSource == .tokenFile, "Encore's Keychain copy was removed (the token is re-adopted from the shared file)")
        check((try? String(contentsOf: reset.tokenStore.tokenFile, encoding: .utf8)) == "hf_headless_not_a_real_token", "shared token file kept")
        check(deps.modelShelf.downloaded == shelfBefore && !shelfBefore.isEmpty, "downloaded models untouched (\(shelfBefore.count) variants)")
        let root = reset.locations.applicationSupport.deletingLastPathComponent()
        check(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Scratch").path)) ?? ["x"]).isEmpty, "scratch emptied")
        check(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Caches").path)) ?? ["x"]).isEmpty, "caches emptied")

        // Usable straight away, through the same objects the screens use.
        let studio = deps.screenModel("Studio") { StudioModel(deps: deps) }
        check(studio.script.isEmpty, "a fresh Studio has no draft")
        do {
            let clip = root.appendingPathComponent("again.wav")
            try AudioExporter.writeWAV(AudioBuffer(samples: [Float](repeating: 0.1, count: 24_000), sampleRate: 24_000), to: clip)
            let v = try await deps.voices.add(Voice(name: "After", origin: .cloned, transcript: "Hi.", duration: 1), referenceAudio: clip)
            check(deps.voices.voices.map(\.id) == [v.id], "a new voice can be added")
            let id = UUID()
            try FileManager.default.copyItem(at: clip, to: deps.service.history.newAudioURL(id: id))
            try await deps.service.history.insert(GenerationRecord(id: id, kind: .speech, title: "After reset", text: "Hi", modelID: "soprano",
                                                                   modelName: "Soprano", audioPath: deps.service.history.newAudioURL(id: id).path,
                                                                   duration: 1, sampleRate: 24_000))
            for _ in 0..<100 where deps.history.items.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
            check(deps.history.items.map(\.title) == ["After reset"], "a new history record shows up in HistoryStore")
            try deps.presets.save(Preset(name: "Again", modelID: "soprano", parameters: [:], post: PostProcessingOptions()))
            check(deps.presets.presets.count == 1, "a preset can be saved")
        } catch {
            check(false, "using the stores after the reset: \(error)")
        }

        // Twice is safe.
        do {
            let again = try await deps.resetAppData()
            check(again.failures.isEmpty && again.removed.voices == 1 && again.removed.historyItems == 1, "a second run removes only what was added")
            let third = try await deps.resetAppData()
            check(third.failures.isEmpty && third.removed.voices == 0 && third.removed.historyItems == 0 && third.removed.presets == 0,
                  "a third run finds nothing")
        } catch {
            check(false, "running again threw \(error)")
        }
    }

    // MARK: Delete all downloaded models

    private static func proveModelReset(_ deps: AppDependencies) async {
        log("— Delete all downloaded models —")
        let layout = deps.downloads.downloader.store.layout
        let plan = await deps.downloads.catalogRemovalPlan()
        log("sheet would show: \(plan.models.map { "\($0.name) [\($0.variants.map(\.label).joined(separator: ", "))]" }), "
            + "shared \(plan.sharedComponents), \(plan.bytes) bytes; left alone: \(plan.otherRepos)")
        check(Set(plan.models.map(\.id)) == ["soprano", "chatterbox-multilingual", "chatterbox-vc"], "plan names Soprano and both models in the shared repo")
        check(plan.otherRepos == [otherRepo], "plan says the outside repo stays")
        let before = uniqueBytes(layout.root)

        let result: HubRemovalResult
        do { result = try await deps.removeAllModels() } catch { check(false, "removeAllModels threw \(error)"); return }
        let gone = before - uniqueBytes(layout.root)
        log("result: \(result.removedRepos.count) repos, \(result.removedWorkingCopies) working copies, freed \(result.bytesFreed) bytes "
            + "(disk: \(gone)), failures \(result.failures)")
        check(result.failures.isEmpty, "no failures")
        check(result.bytesFreed == plan.bytes && gone == plan.bytes, "reported bytes are what left the disk")
        check(deps.modelShelf.downloaded.isEmpty, "model shelf: nothing downloaded")
        check(!deps.modelShelf.hasDownloadedModel(for: .tts) && !deps.modelShelf.hasDownloadedModel(for: .stt), "pickers have nothing to offer")
        check(deps.downloads.states.values.allSatisfy { $0 == .notDownloaded }, "Models screen: every variant not downloaded")
        check(deps.downloads.totalBytesOnDisk == 0, "Models screen: 0 bytes on disk")
        let other = deps.downloads.downloader.store.repoStatus(otherRepo, revision: "main", patterns: nil)
        check(other.isComplete, "the repo that isn't Encore's is untouched")
        check(FileManager.default.fileExists(atPath: layout.mlxAudioDirectory(otherRepo).path), "its working copy is untouched")
        check(!FileManager.default.fileExists(atPath: layout.mlxAudioDirectory(deps.catalog.model("soprano")!.defaultVariant.repo).path),
              "Soprano's working copy is gone")
        do {
            let again = try await deps.removeAllModels()
            check(again == HubRemovalResult(), "a second run finds nothing")
        } catch {
            check(false, "running again threw \(error)")
        }
    }

    private static func uniqueBytes(_ root: URL) -> Int64 {
        var seen = Set<UInt64>()
        var total: Int64 = 0
        for case let rel as String in FileManager.default.enumerator(atPath: root.path) ?? FileManager.DirectoryEnumerator() {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  seen.insert(st.st_ino).inserted else { continue }
            total += Int64(st.st_size)
        }
        return total
    }
}
#endif
