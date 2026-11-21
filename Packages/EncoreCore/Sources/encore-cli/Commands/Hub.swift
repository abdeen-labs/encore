import EncoreCore
import Foundation

// encore-cli hub whoami
// encore-cli hub info <repo> [--license]
// encore-cli hub access <repo> [--anonymous]
// encore-cli hub download <repo> [--include <glob>]… [--companion <repo>]… [--revision <rev>] [--anonymous] [--cancel-after <s>]
// encore-cli hub status <repo> [--include <glob>]… [--companion <repo>]… [--revision <rev>] [--offline]
// encore-cli hub delete <repo>…
// encore-cli hub size <repo>…
// encore-cli hub center <repo> [--include <glob>]… [--cancel-at <fraction>] [--keep]
//     drives ModelDownloadCenter: download, cancel part-way, retry (resumes), load context, delete
// encore-cli hub token show|set|clear [--keychain-service <name>]   (set reads the token from stdin)

func runHubCommand(_ args: [String]) async throws {
    let opts = HubCLIOptions(args)
    let tokenStore = HubTokenStore(service: opts.value("--keychain-service") ?? HubTokenStore.defaultService)
    let anonymous = opts.flag("--anonymous")
    let service = anonymous ? HubService(token: { nil }) : HubService(tokenStore: tokenStore)
    let store = HubLocalStore()
    let f = ByteCountFormatter()

    switch opts.positional.first {
    case "whoami":
        let account = try await service.whoami()
        print("name: \(account.name)")
        print("role: \(account.tokenRole ?? "?")")

    case "info":
        let repo = try opts.repo()
        let info = try await service.repoInfo(repo)
        print("repo:     \(info.id) @ \(info.commit ?? "?")")
        print("gated:    \(info.gate.rawValue)")
        print("private:  \(info.isPrivate)")
        print("license:  \(info.licenseID ?? "-")\(info.licenseName.map { " (\($0))" } ?? "")")
        if let link = info.licenseLink { print("link:     \(link.absoluteString)") }
        if let prompt = info.gatePrompt { print("gate:     \(prompt.prefix(160).replacingOccurrences(of: "\n", with: " "))…") }
        print("files:    \(info.files.count)")
        if opts.flag("--license") {
            let text = await service.licenseText(for: info)
            print("license text source: \(text.source)  url: \(text.url?.absoluteString ?? "-")")
            if let body = text.text {
                print("---- \(body.count) chars ----")
                print(body.prefix(600))
                if body.count > 600 { print("…") }
            }
        }

    case "access":
        let repo = try opts.repo()
        print("token:  \(anonymous ? "anonymous" : (tokenStore.current().map { "\($0.source.rawValue)" } ?? "none"))")
        print("access: \(try await service.access(repo))")

    case "download":
        let variant = try opts.variant()
        let cancelAfter = opts.value("--cancel-after").flatMap(Double.init)
        let downloader = HubDownloader(service: service, store: store)
        let start = Date()
        let printer = ProgressPrinter()
        let task = Task {
            try await downloader.download(variant) { printer.show($0) }
        }
        if let cancelAfter {
            Task { try await Task.sleep(nanoseconds: UInt64(cancelAfter * 1e9)); task.cancel() }
        }
        do {
            let dirs = try await task.value
            printer.finish()
            print(String(format: "done in %.1f s", Date().timeIntervalSince(start)))
            for (repo, dir) in dirs.sorted(by: { $0.key < $1.key }) { print("\(repo) -> \(dir.path)") }
        } catch is CancellationError {
            printer.finish()
            print("canceled; on disk: \(f.string(fromByteCount: store.status(of: variant).presentBytes))")
        } catch let error as HubError {
            printer.finish()
            if let repo = error.gatedRepo {
                print("GATED \(repo): open \(service.modelPageURL(repo).absoluteString)")
            }
            throw error
        }

    case "status":
        let variant = try opts.variant()
        let status = opts.flag("--offline") ? store.status(of: variant) : await store.status(of: variant, service: service)
        print("state: \(status.state.rawValue)  on disk: \(f.string(fromByteCount: status.presentBytes))"
              + (status.requiredBytes.map { " of \(f.string(fromByteCount: $0))" } ?? ""))
        for r in status.repos {
            print("  \(r.repo)@\(r.revision) commit=\(r.commit ?? "-") verified=\(r.isVerified) complete=\(r.isComplete) files=\(r.presentFiles)/\(r.requiredFiles)")
            if let dir = r.snapshotDirectory { print("    \(dir.path)") }
            for m in r.missingFiles.prefix(5) { print("    missing: \(m)") }
        }

    case "delete":
        let repos = Array(opts.positional.dropFirst())
        guard !repos.isEmpty else { throw HubCLIError("usage: hub delete <repo>…") }
        let freed = try store.delete(repos: repos)
        print("deleted \(repos.joined(separator: ", ")); freed \(f.string(fromByteCount: freed))")

    case "size":
        let repos = Array(opts.positional.dropFirst())
        for repo in repos { print("\(repo)\t\(f.string(fromByteCount: store.blobBytes(repo)))") }
        print("total\t\(f.string(fromByteCount: store.diskUsage(repos: repos)))")

    case "center":
        let variant = try opts.variant()
        try await runDownloadCenterDemo(variant: variant, downloader: HubDownloader(service: service, store: store),
                                        cancelAt: opts.value("--cancel-at").flatMap(Double.init) ?? 0.3, keep: opts.flag("--keep"))

    case "token":
        let file = tokenStore.tokenFile
        switch opts.positional.dropFirst().first {
        case "show":
            let current = tokenStore.current()
            print("source: \(current?.source.rawValue ?? "none")")
            print("file:   \(file.path) \(FileManager.default.fileExists(atPath: file.path) ? "(present)" : "(absent)")")
            if let t = current?.token { print("token:  \(t.prefix(3))…(\(t.count) chars)") }
        case "set":
            guard let line = readLine(strippingNewline: true) else { throw HubCLIError("pipe the token on stdin") }
            try tokenStore.save(line)
            let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int).map { String($0, radix: 8) } ?? "?"
            print("saved to keychain service \(tokenStore.service) and \(file.path) (mode \(mode))")
        case "clear":
            try tokenStore.clear()
            print("cleared keychain service \(tokenStore.service) and \(file.path)")
        default: throw HubCLIError("usage: hub token show|set|clear")
        }

    default:
        print("usage: encore-cli hub whoami | info <repo> [--license] | access <repo> | download <repo> | status <repo> | delete <repo>… | size <repo>… | token show|set|clear")
    }
}

struct HubCLIError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct HubCLIOptions {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ args: [String]) {
        let valued: Set<String> = ["--include", "--companion", "--revision", "--keychain-service", "--cancel-after", "--cancel-at"]
        var i = 0
        while i < args.count {
            let a = args[i]
            if valued.contains(a), i + 1 < args.count { values[a, default: []].append(args[i + 1]); i += 2; continue }
            if a.hasPrefix("--") { flags.insert(a) } else { positional.append(a) }
            i += 1
        }
    }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name]?.last }

    func repo() throws -> String {
        guard positional.count >= 2 else { throw HubCLIError("missing <repo>") }
        return positional[1]
    }

    /// A throwaway variant for the given repo (ModelVariant has no public memberwise init).
    func variant() throws -> ModelVariant {
        var json: [String: Any] = ["id": "cli", "label": "cli", "repo": try repo(), "downloadBytes": 0, "memoryBytes": 0]
        if let inc = values["--include"] { json["allowPatterns"] = inc }
        if let comp = values["--companion"] { json["companionRepos"] = comp }
        if let rev = value("--revision") { json["revision"] = rev }
        return try JSONDecoder().decode(ModelVariant.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

/// Prints a progress line at most once a second.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var latest: HubDownloadProgress?
    private var printed = false
    private let f = ByteCountFormatter()

    func show(_ p: HubDownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        let phaseChanged = p.phase != latest?.phase
        latest = p
        printed = false
        guard Date().timeIntervalSince(last) >= 1 || phaseChanged else { return }
        last = Date()
        line(p)
        printed = true
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if let latest, !printed { line(latest) }
    }

    private func line(_ p: HubDownloadProgress) {
        let speed = p.bytesPerSecond.map { " \(f.string(fromByteCount: Int64($0)))/s" } ?? ""
        let files = p.activeFiles.map { "\($0.path) \(Int(Double($0.completedBytes) / Double(max($0.totalBytes, 1)) * 100))%" }.joined(separator: ", ")
        print(String(format: "[%@] %5.1f%% %@ / %@%@ files %d/%d %@", p.phase.rawValue, p.fractionCompleted * 100,
                     f.string(fromByteCount: p.completedBytes), f.string(fromByteCount: p.totalBytes), speed,
                     p.completedFiles, p.totalFiles, files))
        fflush(stdout)
    }
}

/// Exercises the SwiftUI-facing download center end to end: refresh, download, cancel part-way,
/// retry (resumes), load context, delete.
@MainActor
func runDownloadCenterDemo(variant: ModelVariant, downloader: HubDownloader, cancelAt: Double, keep: Bool) async throws {
    let manifestJSON: [String: Any] = [
        "id": "cli-model", "name": "CLI model", "family": "cli", "summary": "", "tasks": ["stt"], "engine": "cli",
        "variants": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(variant))],
        "license": ["name": "MIT"], "capabilities": [String: Any](), "languages": [], "presetVoices": [], "expressiveTags": [],
        "parameters": [], "maxChunkCharacters": 100, "sampleRate": 16000,
    ]
    let manifest = try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: manifestJSON))
    let center = ModelDownloadCenter(catalog: ModelCatalog(models: [manifest]), downloader: downloader)
    let f = ByteCountFormatter()
    func describe(_ s: ModelDownloadState) -> String {
        switch s {
        case .unknown: return "unknown"
        case .notDownloaded: return "notDownloaded"
        case .partial(let b): return "partial(\(f.string(fromByteCount: b)))"
        case .downloading(let p): return String(format: "downloading %3.0f%% (%@)", p.fractionCompleted * 100, p.phase.rawValue)
        case .downloaded(let b): return "downloaded(\(f.string(fromByteCount: b)))"
        case .failed(let e, let b): return "failed(\(e.localizedDescription), \(f.string(fromByteCount: b)))"
        }
    }
    /// Polls the observable state like a view would, printing changes (downloading at most every 10%).
    func wait(until done: (ModelDownloadState) -> Bool) async throws {
        var last = ""
        var lastTenth = -1
        while true {
            let s = center.state(manifest, variant)
            let d = describe(s)
            let tenth = Int((s.progress?.fractionCompleted ?? 0) * 10)
            if d != last, !s.isDownloading || tenth != lastTenth || !last.hasPrefix("downloading") {
                print("  state: \(d)"); last = d; lastTenth = tenth
            }
            if done(s) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    await center.refresh()
    print("after refresh: \(describe(center.state(manifest, variant)))  total on disk: \(f.string(fromByteCount: center.totalBytesOnDisk))")

    print("download, cancel at \(Int(cancelAt * 100))%")
    center.download(manifest, variant)
    try await wait { s in (s.progress?.fractionCompleted ?? 0) >= cancelAt || (!s.isDownloading && s != .unknown) }
    center.cancel(manifest, variant)
    try await wait { !$0.isDownloading }
    print("after cancel: \(describe(center.state(manifest, variant)))")

    print("retry")
    center.retry(manifest, variant)
    try await wait { !$0.isDownloading }
    let context = center.loadContext(manifest, variant)
    print("loadContext: \(context?.repoDirectories.map { "\($0.key) -> \($0.value.lastPathComponent)" } ?? ["nil"])")
    print("total on disk: \(f.string(fromByteCount: center.totalBytesOnDisk))")

    if !keep {
        let freed = try await center.delete(manifest, variant)
        print("deleted, freed \(f.string(fromByteCount: freed)); state: \(describe(center.state(manifest, variant)))")
    }
}
