import Foundation
import Testing
@testable import EncoreCore

// MARK: - Helpers

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("encore-hub-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func variant(_ repo: String, patterns: [String]? = nil, companions: [String]? = nil,
                     companionPatterns: [String: [String]]? = nil, revision: String? = nil) -> ModelVariant {
    var json: [String: Any] = ["id": "v", "label": "v", "repo": repo, "downloadBytes": 0, "memoryBytes": 0]
    if let patterns { json["allowPatterns"] = patterns }
    if let companions { json["companionRepos"] = companions }
    if let companionPatterns { json["companionAllowPatterns"] = companionPatterns }
    if let revision { json["revision"] = revision }
    return try! JSONDecoder().decode(ModelVariant.self, from: JSONSerialization.data(withJSONObject: json))
}

private let commitA = String(repeating: "a", count: 40)

/// Writes a repo into a fake cache the way huggingface_hub would. `linked: false` leaves a blob without its snapshot link.
private func install(_ layout: HubCacheLayout, repo: String, commit: String = commitA, files: [(path: String, content: String, linked: Bool)],
                     writeRef: Bool = true, writeTree: Bool = true) -> [HubRepoFile] {
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
        if f.linked {
            let link = layout.snapshotFile(repo, commit: commit, path: f.path)
            try! fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! fm.createSymbolicLink(atPath: link.path, withDestinationPath: HubCacheLayout.symlinkTarget(path: f.path, etag: entry.etag))
        }
    }
    try! fm.createDirectory(at: layout.snapshotDirectory(repo, commit: commit), withIntermediateDirectories: true)
    if writeRef {
        try! fm.createDirectory(at: layout.refFile(repo, ref: "main").deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(commit.utf8).write(to: layout.refFile(repo, ref: "main"))
    }
    if writeTree { HubTreeCache(layout: layout).save(entries, repo: repo, commit: commit) }
    return entries
}

// MARK: - Cache layout

@Test func hubCacheLayoutPaths() {
    let layout = HubCacheLayout(root: URL(fileURLWithPath: "/c/hub"))
    #expect(HubCacheLayout.folderName(repo: "mlx-community/Soprano-1.1-80M-bf16") == "models--mlx-community--Soprano-1.1-80M-bf16")
    #expect(HubCacheLayout.repo(fromFolderName: "models--mlx-community--Soprano-1.1-80M-bf16") == "mlx-community/Soprano-1.1-80M-bf16")
    #expect(HubCacheLayout.repo(fromFolderName: "datasets--a--b") == nil)
    #expect(HubCacheLayout.repo(fromFolderName: ".locks") == nil)
    #expect(layout.blob("a/b", etag: "e").path == "/c/hub/models--a--b/blobs/e")
    #expect(layout.incompleteBlob("a/b", etag: "e").path == "/c/hub/models--a--b/blobs/e.incomplete")
    #expect(layout.refFile("a/b", ref: "main").path == "/c/hub/models--a--b/refs/main")
    #expect(layout.snapshotFile("a/b", commit: "c", path: "x/y.json").path == "/c/hub/models--a--b/snapshots/c/x/y.json")
    #expect(layout.lockFile("a/b", etag: "e").path == "/c/hub/.locks/models--a--b/e.lock")
    #expect(HubCacheLayout.symlinkTarget(path: "config.json", etag: "e") == "../../blobs/e")
    #expect(HubCacheLayout.symlinkTarget(path: "audio_tokenizer/sub/model.safetensors", etag: "e") == "../../../../blobs/e")
}

@Test func hubCommitAndPathValidation() {
    #expect(HubCacheLayout.isCommitHash(commitA))
    #expect(!HubCacheLayout.isCommitHash("main"))
    #expect(!HubCacheLayout.isCommitHash(String(repeating: "A", count: 40)))
    #expect(HubCacheLayout.isSafeRepoPath("a/b.json"))
    for bad in ["", "/etc/passwd", "../x", "a/../b", "a//b", "./a", "a\\b"] { #expect(!HubCacheLayout.isSafeRepoPath(bad), "\(bad)") }
}

@Test func hubLocalCommitReadsRefs() throws {
    let layout = HubCacheLayout(root: tempDir())
    #expect(layout.localCommit("a/b", revision: "main") == nil)
    #expect(layout.localCommit("a/b", revision: commitA) == commitA)
    try FileManager.default.createDirectory(at: layout.refFile("a/b", ref: "main").deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((commitA + "\n").utf8).write(to: layout.refFile("a/b", ref: "main"))
    #expect(layout.localCommit("a/b", revision: "main") == commitA)
}

// MARK: - Glob (parity with huggingface_hub's filter_repo_objects / fnmatchcase)

@Test(arguments: [
    ("config.json", "*.json", true),
    ("audio_tokenizer/config.json", "*.json", true),     // `*` crosses `/` in fnmatch
    ("audio_tokenizer/config.json", "audio_tokenizer/", true),
    ("audio_tokenizer/x/y.bin", "audio_tokenizer/", true),
    ("audio_tokenizerX/y.bin", "audio_tokenizer/", false),
    ("Model.safetensors", "model.safetensors", false),  // case-sensitive
    ("model-00001-of-00002.safetensors", "model-?????-of-?????.safetensors", true),
    ("voices/af_heart.pt", "voices/[!b]*", true),
    ("voices/bf_emma.pt", "voices/[!b]*", false),
    ("weights_q4.npz", "weights_q[0-9].npz", true),
    ("a[b", "a[b", true),                               // unclosed bracket is literal
    ("x]", "[]]", false),
    ("]", "[]]", true),
    ("README.md", "*.safetensors", false),
    ("dir\\file.txt", "dir\\", false),
])
func hubGlobMatchesPython(path: String, pattern: String, expected: Bool) {
    #expect(HubGlob.matches(path, allow: [pattern]) == expected)
}

@Test func hubGlobNilAllowsEverything() {
    #expect(HubGlob.filter(["a", "b/c"], allow: nil) == ["a", "b/c"])
    #expect(HubGlob.filter(["a", "b/c"], allow: []) == [])
    #expect(HubGlob.filter(["x.json", "y.bin", "d/z.json"], allow: ["*.json"]) == ["x.json", "d/z.json"])
}

// MARK: - Error mapping

@Test func hubErrorMapping() {
    #expect(HubError.from(status: 200, errorCode: nil, errorMessage: nil, repo: "a/b") == nil)
    #expect(HubError.from(status: 401, errorCode: "GatedRepo", errorMessage: "restricted", repo: "a/b")
            == .gated(repo: "a/b", kind: nil, message: "restricted"))
    #expect(HubError.from(status: 403, errorCode: "GatedRepo", errorMessage: "pending", repo: "a/b")?.gatedRepo == "a/b")
    #expect(HubError.from(status: 401, errorCode: nil, errorMessage: "Invalid username or password.", repo: "a/b")
            == .repoNotFoundOrPrivate(repo: "a/b"))
    #expect(HubError.from(status: 404, errorCode: "EntryNotFound", errorMessage: nil, repo: "a/b", path: "x")
            == .fileNotFound(repo: "a/b", path: "x"))
    #expect(HubError.from(status: 404, errorCode: "RevisionNotFound", errorMessage: nil, repo: "a/b", revision: "v9")
            == .revisionNotFound(repo: "a/b", revision: "v9"))
    #expect(HubError.from(status: 401, errorCode: nil, errorMessage: nil, repo: nil) == .invalidToken)
    #expect(HubError.from(status: 429, errorCode: nil, errorMessage: nil, retryAfter: "7", repo: "a/b") == .rateLimited(retryAfter: 7))
    #expect(HubError.from(status: 503, errorCode: nil, errorMessage: "down", repo: "a/b") == .server(status: 503, message: "down"))
    #expect(HubError.from(status: 503, errorCode: nil, errorMessage: nil, repo: nil)?.isTransient == true)
    #expect(HubError.gated(repo: "a/b", kind: .auto, message: "m").isTransient == false)
    #expect(HubError.from(URLError(.notConnectedToInternet)) == .offline)
    #expect(HubError.from(URLError(.timedOut)).isTransient)
}

// MARK: - API parsing

@Test func hubParsesTreeEntriesAndPagination() {
    let lfs = HubService.parseTreeEntry(["type": "file", "oid": "1b91", "size": 74418182, "path": "weights.npz", "xetHash": "109d",
                                        "lfs": ["oid": "d5a3", "size": 74418182, "pointerSize": 133]])
    #expect(lfs == HubRepoFile(path: "weights.npz", size: 74418182, blobID: "1b91", lfsSHA256: "d5a3", xetHash: "109d"))
    #expect(lfs?.etag == "d5a3" && lfs?.isLFS == true)
    let small = HubService.parseTreeEntry(["type": "file", "oid": "a5f9", "size": 262, "path": "config.json"])
    #expect(small?.etag == "a5f9" && small?.isLFS == false)
    #expect(HubService.parseTreeEntry(["type": "directory", "oid": "x", "size": 0, "path": "prompts"]) == nil)

    let link = #"<https://huggingface.co/api/models/a/b/tree/main?recursive=true&cursor=abc>; rel="next""#
    #expect(HubService.nextLink(link)?.absoluteString == "https://huggingface.co/api/models/a/b/tree/main?recursive=true&cursor=abc")
    #expect(HubService.nextLink(#"<https://x/y>; rel="prev""#) == nil)
    #expect(HubService.nextLink(nil) == nil)
}

@Test func hubParsesRepoInfo() {
    let endpoint = URL(string: "https://huggingface.co")!
    let gated = HubService.parseRepoInfo([
        "id": "meta-llama/Llama-3.2-1B", "sha": commitA, "gated": "manual", "private": false,
        "cardData": ["license": "llama3.2", "license_link": "LICENSE.txt", "extra_gated_prompt": "### LLAMA 3.2 COMMUNITY LICENSE"],
        "siblings": [["rfilename": "LICENSE.txt"], ["rfilename": "README.md"], ["rfilename": "USE_POLICY.md"]],
    ], repo: "meta-llama/Llama-3.2-1B", endpoint: endpoint)
    #expect(gated.gate == .manual)
    #expect(gated.licenseID == "llama3.2")
    #expect(gated.licenseLink?.absoluteString == "https://huggingface.co/meta-llama/Llama-3.2-1B/blob/main/LICENSE.txt")
    #expect(gated.gatePrompt?.hasPrefix("### LLAMA") == true)
    #expect(HubService.licenseFileCandidates(gated) == ["LICENSE.txt"])

    let open = HubService.parseRepoInfo(["id": "x/y", "gated": false, "cardData": ["license": ["mit"]],
                                         "siblings": [["rfilename": "COPYING"], ["rfilename": "LICENSE"], ["rfilename": "sub/LICENSE"],
                                                      ["rfilename": "license.py"], ["rfilename": "LICENSE-MODEL.md"]]],
                                        repo: "x/y", endpoint: endpoint)
    #expect(open.gate == HubGateKind.none)
    #expect(open.licenseID == "mit")
    #expect(HubService.licenseFileCandidates(open) == ["LICENSE", "LICENSE-MODEL.md", "COPYING"])
    #expect(HubService.parseRepoInfo(["gated": "auto"], repo: "a/b", endpoint: endpoint).gate == .auto)
    #expect(HubLicenseCatalog.spdxID(for: "apache-2.0") == "Apache-2.0")
    #expect(HubLicenseCatalog.spdxID(for: "other") == nil)
}

// MARK: - Bundled license texts

@Test func bundledLicenseTextsCoverTheCatalog() {
    let bundled = HubLicenseCatalog.bundledIDs
    // Every license the catalog declares.
    let (catalog, _) = ModelCatalog.bundled()
    var expected: Set<String> = []
    #expect(!catalog.models.isEmpty)
    for manifest in catalog.models {
        // A custom license (no SPDX id) has no standard text; the details view links to the model's page instead.
        if let id = HubLicenseCatalog.spdxID(for: manifest.license.name) { expected.insert(id) }
    }
    #expect(expected.isSubset(of: bundled), "missing: \(expected.subtracting(bundled).sorted())")
    for id in bundled {
        #expect(HubLicenseCatalog.bundledText(for: id)?.isEmpty == false, "\(id) is empty")
    }
}

@Test func bundledLicenseLookupAcceptsHubSpellings() throws {
    let apache = try #require(HubLicenseCatalog.bundledText(for: "apache-2.0"))
    #expect(HubLicenseCatalog.bundledText(for: "Apache-2.0") == apache)
    #expect(HubLicenseCatalog.bundledText(for: "mit") == HubLicenseCatalog.bundledText(for: "MIT"))
    #expect(HubLicenseCatalog.bundledText(for: "cc-by-nc-4.0") == HubLicenseCatalog.bundledText(for: "CC-BY-NC-4.0"))
    #expect(HubLicenseCatalog.bundledText(for: "gpl-3.0") == nil)  // known id, not bundled
    #expect(HubLicenseCatalog.bundledText(for: "llama3.2") == nil)
    #expect(HubLicenseCatalog.bundledText(for: nil) == nil)
}

@Test func licenseTextUsesBundledTextAndNeverTheNetwork() async {
    // A closed local port: any request would fail, and nothing here should make one (no files, no README, no link).
    let hub = HubService(endpoint: URL(string: "http://127.0.0.1:9")!, token: { nil })
    let page = URL(string: "https://huggingface.co/x/y")!
    let mit = await hub.licenseText(for: HubRepoInfo(id: "x/y", licenseID: "mit", pageURL: page))
    #expect(mit.source == .standard("MIT"))
    #expect(mit.text != nil && mit.text == HubLicenseCatalog.bundledText(for: "MIT"))
    #expect(mit.url == page)

    // Not bundled, no gate prompt: no text, and the link is the model's page.
    let other = await hub.licenseText(for: HubRepoInfo(id: "x/y", licenseID: "gpl-3.0", pageURL: page))
    #expect(other.source == HubLicenseText.Source.none && other.text == nil && other.url == page)

    let gated = await hub.licenseText(for: HubRepoInfo(id: "x/y", licenseID: "llama3.2", gatePrompt: "Terms", pageURL: page))
    #expect(gated.source == .gatePrompt && gated.text == "Terms")
}

@Test func hubExtractsLicenseSectionFromModelCard() {
    let card = """
    ---
    license: other
    ---
    # Model
    Intro.
    ## License
    Code is Apache-2.0; weights are CC-BY-NC-4.0.

    ### Notes
    Attribution required.
    ## Citation
    @misc{}
    """
    #expect(HubService.licenseSection(ofModelCard: card) == "Code is Apache-2.0; weights are CC-BY-NC-4.0.\n\n### Notes\nAttribution required.")
    #expect(HubService.licenseSection(ofModelCard: "# A\nno license here") == nil)
}

// MARK: - Tree cache (huggingface_hub's trees/<commit>.json)

@Test func hubTreeCacheReadsPythonFormatAndRoundTrips() throws {
    let python = #"""
    {"format_version": 1, "files": {
      "config.json": {"size": 335, "blob_id": "943d"},
      "weights.npz": {"size": 50716332, "blob_id": "bcac", "lfs_sha256": "c148", "lfs_size": 50716332, "xet_hash": "e18d"}}}
    """#
    let files = try #require(HubTreeCache.decode(Data(python.utf8)))
    #expect(files == [HubRepoFile(path: "config.json", size: 335, blobID: "943d"),
                      HubRepoFile(path: "weights.npz", size: 50716332, blobID: "bcac", lfsSHA256: "c148", xetHash: "e18d")])
    #expect(HubTreeCache.decode(try HubTreeCache.encode(files)) == files)
    #expect(HubTreeCache.decode(Data(#"{"format_version": 2, "files": {}}"#.utf8)) == nil)
}

// MARK: - Hashing

@Test func hubContentHashesMatchHubIDs() {
    // `git hash-object` of "hello\n" is ce013625030ba8dba906f756967f9e9ca394464a.
    var git = ContentHasher(file: HubRepoFile(path: "x", size: 6, blobID: "ce013625030ba8dba906f756967f9e9ca394464a"))
    git.update(Data("hel".utf8)); git.update(Data("lo\n".utf8))
    #expect(git.matches(HubRepoFile(path: "x", size: 6, blobID: "ce013625030ba8dba906f756967f9e9ca394464a")))
    var lfs = ContentHasher(file: HubRepoFile(path: "x", size: 6, blobID: "", lfsSHA256: "x"))
    lfs.update(Data("hello\n".utf8))
    #expect(lfs.hex() == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
}

// MARK: - Local state

@Test func hubStatusDownloadedPartialAndMissing() throws {
    let layout = HubCacheLayout(root: tempDir())
    let store = HubLocalStore(layout: layout)
    #expect(store.status(of: variant("a/b")).state == .notDownloaded)

    _ = install(layout, repo: "a/b", files: [("config.json", "{}", true), ("model.safetensors", "weights", true)])
    let ok = store.status(of: variant("a/b"))
    #expect(ok.state == .downloaded)
    #expect(ok.presentBytes == 9 && ok.requiredBytes == 9)
    #expect(ok.repoDirectories == ["a/b": layout.snapshotDirectory("a/b", commit: commitA)])

    // Remove one link: the snapshot directory still exists, but the variant isn't downloaded.
    try FileManager.default.removeItem(at: layout.snapshotFile("a/b", commit: commitA, path: "model.safetensors"))
    let partial = store.status(of: variant("a/b"))
    #expect(partial.state == .partial)
    #expect(partial.repoDirectories == nil)
    #expect(partial.repos[0].missingFiles == ["model.safetensors"])
    // …unless the variant only needs the file that is present.
    #expect(store.status(of: variant("a/b", patterns: ["*.json"])).state == .downloaded)
}

@Test func hubStatusCatchesIncompleteSubfolder() {
    // The k2-fsa/OmniVoice case: refs/main and a snapshot exist, but audio_tokenizer/ was never linked.
    let layout = HubCacheLayout(root: tempDir())
    _ = install(layout, repo: "k/omni", files: [("config.json", "{}", true), ("model.safetensors", "w", true),
                                               ("audio_tokenizer/config.json", "{\"a\":1}", false),
                                               ("audio_tokenizer/model.safetensors", "tok", false)])
    try? FileManager.default.removeItem(at: layout.blob("k/omni", etag: HubTreeCache(layout: layout).files(repo: "k/omni", commit: commitA)!
        .first { $0.path == "audio_tokenizer/model.safetensors" }!.etag))
    let status = HubLocalStore(layout: layout).status(of: variant("k/omni"))
    #expect(status.state == .partial)
    #expect(Set(status.repos[0].missingFiles) == ["audio_tokenizer/config.json", "audio_tokenizer/model.safetensors"])
    #expect(status.repos[0].presentFiles == 2 && status.repos[0].requiredFiles == 4)
}

@Test func hubStatusWithoutFileListIsUnverified() {
    let layout = HubCacheLayout(root: tempDir())
    _ = install(layout, repo: "a/b", files: [("config.json", "{}", true)], writeTree: false)
    let status = HubLocalStore(layout: layout).status(of: variant("a/b"))
    #expect(status.state == .partial)
    #expect(status.repos[0].isVerified == false)
    #expect(status.repos[0].presentFiles == 1)
}

@Test func hubStatusCountsPartialBlobsBeforeRefsExist() throws {
    let layout = HubCacheLayout(root: tempDir())
    try FileManager.default.createDirectory(at: layout.blobsDirectory("a/b"), withIntermediateDirectories: true)
    try Data(count: 1000).write(to: layout.incompleteBlob("a/b", etag: "abc"))
    let status = HubLocalStore(layout: layout).status(of: variant("a/b"))
    #expect(status.state == .partial)
    #expect(status.presentBytes == 1000)
}

@Test func hubStatusCoversCompanionsWithTheirOwnPatterns() {
    let layout = HubCacheLayout(root: tempDir())
    _ = install(layout, repo: "m/main", files: [("config.json", "{}", true), ("big.bin", "x", false)])
    _ = install(layout, repo: "m/codec", files: [("codec.safetensors", "c", true), ("extra.bin", "e", false)])
    let store = HubLocalStore(layout: layout)
    let v = variant("m/main", patterns: ["*.json"], companions: ["m/codec"], companionPatterns: ["m/codec": ["*.safetensors"]])
    #expect(v.allowPatterns(for: "m/codec") == ["*.safetensors"])
    #expect(v.revision(for: "m/codec") == "main")
    #expect(store.status(of: v).state == .downloaded)
    #expect(store.status(of: variant("m/main", patterns: ["*.json"], companions: ["m/codec"])).state == .partial)
}

// MARK: - Deletion

@Test func hubDeleteRemovesOnlyThatRepo() throws {
    let layout = HubCacheLayout(root: tempDir())
    _ = install(layout, repo: "a/one", files: [("w.bin", "12345", true)])
    _ = install(layout, repo: "a/two", files: [("w.bin", "12345", true)])
    try FileManager.default.createDirectory(at: layout.locksDirectory("a/one"), withIntermediateDirectories: true)
    let store = HubLocalStore(layout: layout)
    #expect(store.diskUsage(repos: ["a/one", "a/two"]) == 10)
    let freed = try store.delete(repos: ["a/one"])
    #expect(freed == 5)
    #expect(!FileManager.default.fileExists(atPath: layout.repoDirectory("a/one").path))
    #expect(!FileManager.default.fileExists(atPath: layout.locksDirectory("a/one").path))
    #expect(store.status(of: variant("a/two")).state == .downloaded)
}

@Test func hubDeleteSweepsSharedBlobStore() throws {
    // huggingface_hub ≥ 2.4: repo blobs may link into <hub>/blobs/<xx>/<xet hash>, with a .refs manifest.
    let root = tempDir()
    let layout = HubCacheLayout(root: root)
    let fm = FileManager.default
    let hash = String(repeating: "e1", count: 32)
    let storeDir = root.appendingPathComponent("blobs/e1")
    try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
    try Data("1\n".utf8).write(to: root.appendingPathComponent("blobs/.huggingface-shared-blobs"))
    try Data("payload".utf8).write(to: storeDir.appendingPathComponent(hash))
    var refs = ""
    for repo in ["a/one", "a/two"] {
        try fm.createDirectory(at: layout.blobsDirectory(repo), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: layout.blob(repo, etag: "sha").path, withDestinationPath: "../../blobs/e1/\(hash)")
        refs += "\(HubCacheLayout.folderName(repo: repo))/blobs/sha\n"
    }
    try Data(refs.utf8).write(to: storeDir.appendingPathComponent(hash + ".refs"))
    let store = HubLocalStore(layout: layout)
    #expect(store.blobBytes("a/one") == 7)

    #expect(try store.delete(repos: ["a/one"]) == 0)  // still referenced by a/two
    #expect(fm.fileExists(atPath: storeDir.appendingPathComponent(hash).path))
    #expect(try String(contentsOf: storeDir.appendingPathComponent(hash + ".refs"), encoding: .utf8) == "models--a--two/blobs/sha\n")

    #expect(try store.delete(repos: ["a/two"]) == 7)
    #expect(!fm.fileExists(atPath: storeDir.appendingPathComponent(hash).path))
    #expect(!fm.fileExists(atPath: storeDir.appendingPathComponent(hash + ".refs").path))
}

@Test func hubDeleteKeepsSharedPayloadWithoutManifest() throws {
    let root = tempDir()
    let layout = HubCacheLayout(root: root)
    let hash = String(repeating: "ab", count: 32)
    let payload = root.appendingPathComponent("blobs/ab/\(hash)")
    try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: payload)
    try FileManager.default.createDirectory(at: layout.blobsDirectory("a/one"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: layout.blob("a/one", etag: "s").path, withDestinationPath: "../../blobs/ab/\(hash)")
    try HubLocalStore(layout: layout).delete(repos: ["a/one"])
    #expect(FileManager.default.fileExists(atPath: payload.path))  // never delete on missing metadata
}

// MARK: - Token store

@Test func hubTokenStoreSaveAdoptClear() throws {
    let dir = tempDir()
    let file = dir.appendingPathComponent("hf/token")
    let store = HubTokenStore(service: "dev.abdeen.encore.huggingface.unit-test-\(UUID().uuidString)", tokenFile: file, readsEnvironment: false)
    defer { try? store.clear() }
    #expect(store.current()?.token == nil)

    // A token already in the HF token file is adopted into the Keychain.
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("hf_fromfile\n".utf8).write(to: file)
    #expect(store.current()?.source == .tokenFile)
    #expect(store.current()?.source == .keychain)
    #expect(store.token() == "hf_fromfile")

    try store.save("  hf_new  ")
    #expect(store.token() == "hf_new")
    #expect(try String(contentsOf: file, encoding: .utf8) == "hf_new")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    try store.clear()
    #expect(store.current()?.token == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

/// A store on a throwaway Keychain service and a token file in a temp folder: never the user's real token.
private func scratchTokenStore() -> (store: HubTokenStore, file: URL) {
    let file = tempDir().appendingPathComponent("hf/token")
    let store = HubTokenStore(service: "dev.abdeen.encore.huggingface.unit-test-\(UUID().uuidString)", tokenFile: file, readsEnvironment: false)
    return (store, file)
}

private func writeFile(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
}

@Test func hubTokenFileWinsOverKeychain() throws {
    let (store, file) = scratchTokenStore()
    defer { try? store.clear() }
    try store.save("hf_old")
    #expect(store.current()?.source == .keychain)

    // Something else (the hf tool) logs in with another token: the file wins and the Keychain copy follows.
    try writeFile("hf_new\n", to: file)
    let first = store.current()
    #expect(first?.token == "hf_new" && first?.source == .tokenFile)
    #expect(try store.keychainToken() == "hf_new")
    #expect(store.current()?.source == .keychain)  // now in agreement

    // No file: the Keychain copy is used, and the file isn't written back.
    try FileManager.default.removeItem(at: file)
    let keychainOnly = store.current()
    #expect(keychainOnly?.token == "hf_new" && keychainOnly?.source == .keychain)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    // A blank file counts as no file.
    try writeFile("  \n", to: file)
    #expect(store.current()?.token == "hf_new")
    #expect(try String(contentsOf: file, encoding: .utf8) == "  \n")
}

@Test func hubTokenEncoreOnlySignOutIgnoresFileUntilSignIn() throws {
    let (store, file) = scratchTokenStore()
    defer { try? store.clear() }
    try store.save("hf_a")
    #expect(!store.isSignedOutOfEncoreOnly)

    try store.signOutOfEncoreOnly()
    #expect(store.isSignedOutOfEncoreOnly)
    #expect(!store.hasKeychainToken)
    #expect(try String(contentsOf: file, encoding: .utf8) == "hf_a")  // the shared file is left alone
    #expect(store.current()?.token == nil)

    // A relaunch is a fresh store on the same service and file: still signed out, even when the file changes.
    let relaunched = HubTokenStore(service: store.service, tokenFile: file, readsEnvironment: false)
    #expect(relaunched.isSignedOutOfEncoreOnly)
    #expect(relaunched.current()?.token == nil)
    try writeFile("hf_b", to: file)
    #expect(relaunched.current()?.token == nil)
    #expect(!relaunched.hasKeychainToken)  // nothing was adopted

    // Signing in again in Encore ends it.
    try relaunched.save("hf_c")
    #expect(!relaunched.isSignedOutOfEncoreOnly)
    #expect(relaunched.current()?.token == "hf_c")

    // Choosing to use the shared token again picks up the file.
    try store.signOutOfEncoreOnly()
    try writeFile("hf_d", to: file)
    #expect(store.current()?.token == nil)
    try store.clearEncoreOnlySignOut()
    #expect(store.current()?.token == "hf_d")

    // Signing out everywhere clears the state too.
    try store.signOutOfEncoreOnly()
    try store.clear()
    #expect(!store.isSignedOutOfEncoreOnly)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@MainActor @Test func hubAccountEncoreOnlySignOutSurvivesRefresh() async throws {
    let (store, file) = scratchTokenStore()
    defer { try? store.clear() }
    try store.save("hf_a")
    // A closed local port: whoami would fail as "unreachable", and the signed-out path makes no request at all.
    let account = HubAccountModel(tokenStore: store, endpoint: URL(string: "http://127.0.0.1:9")!)
    #expect(account.signOutOfEncoreOnly())
    #expect(account.status == .signedOut && account.isSignedOutOfEncoreOnly && account.sharedTokenFileExists)

    let relaunched = HubAccountModel(tokenStore: HubTokenStore(service: store.service, tokenFile: file, readsEnvironment: false),
                                     endpoint: URL(string: "http://127.0.0.1:9")!)
    await relaunched.refresh()
    #expect(relaunched.status == .signedOut)
    #expect(relaunched.isSignedOutOfEncoreOnly && relaunched.tokenSource == nil)

    account.signOut()
    #expect(!store.isSignedOutOfEncoreOnly && !account.isSignedOutOfEncoreOnly)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

// MARK: - Download center

@MainActor @Test func hubDownloadStateFromStatus() {
    let repo = HubRepoStatus(repo: "a/b", revision: "main", commit: commitA, snapshotDirectory: nil, isVerified: true,
                             isComplete: false, requiredFiles: 2, presentFiles: 1, requiredBytes: 10, presentBytes: 4, missingFiles: [])
    #expect(ModelDownloadCenter.state(for: HubVariantStatus(repos: [repo], state: .partial)) == .partial(bytesOnDisk: 4))
    #expect(ModelDownloadCenter.state(for: HubVariantStatus(repos: [], state: .notDownloaded)) == .notDownloaded)
    let p = HubDownloadProgress(phase: .downloading, totalBytes: 200, completedBytes: 50, bytesPerSecond: 25,
                                activeFiles: [], totalFiles: 2, completedFiles: 1)
    #expect(p.fractionCompleted == 0.25)
    #expect(p.estimatedSecondsRemaining == 6)
}


// MARK: - Shared repos

private func manifest(_ id: String, variants: [(id: String, repo: String, companions: [String])]) -> ModelManifest {
    let json: [String: Any] = [
        "id": id, "name": id, "family": id, "summary": "", "tasks": ["tts"], "engine": "x",
        "variants": variants.map { ["id": $0.id, "label": "8-bit", "repo": $0.repo, "companionRepos": $0.companions,
                                    "downloadBytes": 0, "memoryBytes": 0] as [String: Any] },
        "license": ["name": "MIT"], "capabilities": [String: Any](), "languages": [Any](), "presetVoices": [Any](),
        "expressiveTags": [Any](), "parameters": [Any](), "maxChunkCharacters": 300, "sampleRate": 24000,
    ]
    return try! JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func hubCompanionAloneIsNotAPartialDownload() {
    let layout = HubCacheLayout(root: tempDir())
    _ = install(layout, repo: "m/codec", files: [("codec.safetensors", "c", true)])
    let store = HubLocalStore(layout: layout)
    // The model's own repo has nothing on disk; only the shared companion does.
    #expect(store.status(of: variant("m/turbo", companions: ["m/codec"])).state == .notDownloaded)
    _ = install(layout, repo: "m/turbo", files: [("w.bin", "12345", true)])
    #expect(store.status(of: variant("m/turbo", companions: ["m/codec"])).state == .downloaded)
}

@MainActor @Test func hubDeleteHandlesSharedCompanionsAndSharedRepos() async throws {
    let layout = HubCacheLayout(root: tempDir())
    let store = HubLocalStore(layout: layout)
    // turbo (two variants) and multi share a companion; multi and changer live in the same repo.
    let turbo = manifest("turbo", variants: [("8bit", "m/turbo-8", ["m/codec"]), ("4bit", "m/turbo-4", ["m/codec"])])
    let multi = manifest("multi", variants: [("v3", "m/multi", ["m/codec"])])
    let changer = manifest("changer", variants: [("v3", "m/multi", ["m/codec"])])
    for repo in ["m/turbo-8", "m/multi", "m/codec"] { _ = install(layout, repo: repo, files: [("w.bin", "12345", true)]) }
    let center = ModelDownloadCenter(catalog: ModelCatalog(models: [turbo, multi, changer]),
                                     downloader: HubDownloader(store: store))
    await center.refresh(verifyOnline: false)
    func exists(_ repo: String) -> Bool { FileManager.default.fileExists(atPath: layout.repoDirectory(repo).path) }

    // The variant that was never downloaded isn't "partial" just because the shared companion is there.
    #expect(center.state(turbo, turbo.variants[1]) == .notDownloaded)

    // Deleting turbo removes its own repo and keeps the companion another model still needs.
    #expect(center.deletionPlan(turbo, turbo.variants[0]).repos == ["m/turbo-8"])
    try await center.delete(turbo, turbo.variants[0])
    #expect(!exists("m/turbo-8") && exists("m/codec"))
    #expect(center.state(turbo, turbo.variants[0]) == .notDownloaded)
    #expect(center.state(multi, multi.variants[0]).isDownloaded)

    // Deleting a model that shares its repo with another names that model and removes both, and now that
    // nothing on disk needs the companion, it goes too.
    let plan = center.deletionPlan(multi, multi.variants[0])
    #expect(plan.alsoRemoves.map(\.id) == ["changer"])
    #expect(Set(plan.repos) == ["m/multi", "m/codec"])
    try await center.delete(multi, multi.variants[0])
    #expect(!exists("m/multi") && !exists("m/codec"))
    #expect(center.state(multi, multi.variants[0]) == .notDownloaded)
    #expect(center.state(changer, changer.variants[0]) == .notDownloaded)
}
