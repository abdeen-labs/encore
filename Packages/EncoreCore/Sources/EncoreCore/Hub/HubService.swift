import Foundation

/// The Hugging Face Hub API calls Encore needs: account, repo info and licence, access checks,
/// revision resolution and file listings. Stateless and cheap to create.
public struct HubService: Sendable {
    public var endpoint: URL
    private let tokenProvider: @Sendable () -> String?
    let session: URLSession

    /// `HF_ENDPOINT` if set, else https://huggingface.co.
    public static var defaultEndpoint: URL {
        if let s = ProcessInfo.processInfo.environment["HF_ENDPOINT"], let url = URL(string: s), url.scheme != nil {
            return url
        }
        return URL(string: "https://huggingface.co")!
    }

    public init(endpoint: URL = HubService.defaultEndpoint, tokenStore: HubTokenStore = .standard) {
        self.init(endpoint: endpoint, token: { tokenStore.token() })
    }

    public init(endpoint: URL = HubService.defaultEndpoint, token: @escaping @Sendable () -> String?) {
        self.endpoint = endpoint
        self.tokenProvider = token
        self.session = HubSession.api
    }

    public var token: String? { tokenProvider() }

    /// The repo's page, where gates are accepted.
    public func modelPageURL(_ repo: String) -> URL { url(path: Self.escapeRepo(repo)) }

    // MARK: Account

    /// Validates a token. Pass a token to check one before saving it; nil checks the stored token.
    public func whoami(token explicit: String? = nil) async throws -> HubAccount {
        guard let token = explicit ?? token else { throw HubError.invalidToken }
        var req = URLRequest(url: url(path: "api/whoami-v2"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(req)
        if response.statusCode == 401 { throw HubError.invalidToken }
        try Self.check(response, repo: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { throw HubError.invalidResponse("whoami") }
        let access = (json["auth"] as? [String: Any])?["accessToken"] as? [String: Any]
        let avatar = (json["avatarUrl"] as? String).flatMap { URL(string: $0, relativeTo: endpoint)?.absoluteURL }
        return HubAccount(name: name, fullName: json["fullname"] as? String, avatarURL: avatar,
                          tokenRole: access?["role"] as? String, tokenName: access?["displayName"] as? String)
    }

    // MARK: Repo info and licence

    public func repoInfo(_ repo: String) async throws -> HubRepoInfo {
        let (data, response) = try await send(request(path: "api/models/\(Self.escapeRepo(repo))"))
        try Self.check(response, repo: repo)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubError.invalidResponse("model info")
        }
        return Self.parseRepoInfo(json, repo: repo, endpoint: endpoint)
    }

    static func parseRepoInfo(_ json: [String: Any], repo: String, endpoint: URL) -> HubRepoInfo {
        let card = json["cardData"] as? [String: Any] ?? [:]
        let gate: HubGateKind
        switch json["gated"] {
        case let s as String: gate = HubGateKind(rawValue: s) ?? .auto
        case let b as Bool: gate = b ? .auto : .none
        default: gate = .none
        }
        func string(_ v: Any?) -> String? {
            if let s = v as? String { return HubTokenStore.clean(s) }
            if let a = v as? [Any] { return a.compactMap { $0 as? String }.first }
            return nil
        }
        let id = json["id"] as? String ?? repo
        let page = endpoint.appendingPathComponent(id)
        var link: URL?
        if let raw = string(card["license_link"]) {
            if let abs = URL(string: raw), abs.scheme != nil { link = abs }
            else { link = URL(string: page.absoluteString + "/blob/main/" + raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return HubRepoInfo(
            id: id, commit: json["sha"] as? String, gate: gate, isPrivate: json["private"] as? Bool ?? false,
            licenseID: string(card["license"]), licenseName: string(card["license_name"]), licenseLink: link,
            gatePrompt: string(card["extra_gated_prompt"]), gateDescription: string(card["extra_gated_description"]),
            files: (json["siblings"] as? [[String: Any]] ?? []).compactMap { $0["rfilename"] as? String },
            lastModified: (json["lastModified"] as? String).flatMap { iso.date(from: $0) },
            pageURL: page)
    }

    /// The licence text to show for a repo, best source first: the file the card links to, a
    /// LICENSE-like file in the repo, the card's "License" section, the standard text of a
    /// well-known licence (from spdx.org), the gate prompt. Never throws;
    /// a gated repo whose files can't be read falls through to the next source.
    public func licenseText(for info: HubRepoInfo) async -> HubLicenseText {
        let fallbackURL = info.licenseLink ?? HubLicenseCatalog.url(for: info.licenseID)
        for path in Self.licenseFileCandidates(info) {
            if let text = try? await fetchText(repo: info.id, path: path, revision: info.commit ?? "main"), !text.isEmpty {
                let fileURL = URL(string: info.pageURL.absoluteString + "/blob/main/" + Self.escapePath(path))
                return HubLicenseText(source: .repoFile(path), text: text, url: info.licenseLink ?? fileURL)
            }
        }
        if info.files.contains("README.md"),
           let readme = try? await fetchText(repo: info.id, path: "README.md", revision: info.commit ?? "main"),
           let section = Self.licenseSection(ofModelCard: readme) {
            return HubLicenseText(source: .modelCard, text: section, url: fallbackURL)
        }
        if let spdxID = HubLicenseCatalog.spdxID(for: info.licenseID),
           let url = URL(string: "https://spdx.org/licenses/\(spdxID).txt"),
           let (data, response) = try? await send(URLRequest(url: url)), response.statusCode == 200,
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return HubLicenseText(source: .standard(spdxID), text: text, url: fallbackURL)
        }
        if let prompt = info.gatePrompt {
            return HubLicenseText(source: .gatePrompt, text: prompt, url: fallbackURL)
        }
        return HubLicenseText(source: .none, text: nil, url: fallbackURL)
    }

    /// Repo files worth trying as the licence text, most specific first.
    static func licenseFileCandidates(_ info: HubRepoInfo) -> [String] {
        var out: [String] = []
        if let link = info.licenseLink?.absoluteString {
            for marker in ["/blob/", "/resolve/"] {
                let prefix = info.pageURL.absoluteString + marker
                if link.hasPrefix(prefix) {
                    // <page>/blob/<rev>/<path>
                    let rest = link.dropFirst(prefix.count)
                    if let slash = rest.firstIndex(of: "/") {
                        let path = String(rest[rest.index(after: slash)...]).removingPercentEncoding ?? ""
                        if info.files.contains(path) { out.append(path) }
                    }
                }
            }
        }
        let names = info.files.filter { !$0.contains("/") && isLicenseFileName($0) }
        out += names.sorted { rank($0) < rank($1) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func isLicenseFileName(_ name: String) -> Bool {
        let base = name.lowercased()
        let stem = base.split(separator: ".").first.map(String.init) ?? base
        let allowedExt = ["", "md", "txt", "rst"]
        let ext = base.contains(".") ? String(base.split(separator: ".").last!) : ""
        guard allowedExt.contains(ext) else { return false }
        return ["license", "licence", "copying"].contains(stem) || stem.hasPrefix("license-") || stem.hasPrefix("license_")
            || stem.hasPrefix("licence-") || stem.hasPrefix("licence_")
    }

    private static func rank(_ name: String) -> Int {
        let l = name.lowercased()
        if l == "license" || l == "licence" { return 0 }
        if l.hasPrefix("license.") || l.hasPrefix("licence.") { return 1 }
        if l.hasPrefix("copying") { return 3 }
        return 2
    }

    /// The body of the first "License"/"Licence" heading in a model card, without YAML front matter.
    public static func licenseSection(ofModelCard card: String) -> String? {
        var lines = card.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = Array(lines[(end + 1)...])
        }
        func heading(_ line: String) -> Int? {
            let t = line.trimmingCharacters(in: .whitespaces)
            let level = t.prefix(while: { $0 == "#" }).count
            guard level > 0, level <= 6, t.dropFirst(level).first == " " else { return nil }
            return level
        }
        guard let start = lines.firstIndex(where: { line in
            guard heading(line) != nil else { return false }
            let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# \t")).lowercased()
            return title.hasPrefix("license") || title.hasPrefix("licence") || title.hasPrefix("licensing")
        }), let level = heading(lines[start]) else { return nil }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if let l = heading(line), l <= level { break }
            body.append(line)
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// A small text file from a repo (≤ 1 MB).
    public func fetchText(repo: String, path: String, revision: String = "main") async throws -> String {
        let (data, response) = try await send(request(path: Self.resolvePath(repo: repo, revision: revision, path: path)))
        try Self.check(response, repo: repo, path: path, revision: revision)
        guard data.count <= 1 << 20, let text = String(data: data, encoding: .utf8) else {
            throw HubError.invalidResponse("\(path) is not small text")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Access

    /// Whether the stored token (or anonymous access, without one) can download `repo`.
    /// Poll this after the user accepts a gate in the web view.
    public func access(_ repo: String) async throws -> HubAccess {
        let token = self.token
        let (_, response) = try await send(request(path: "api/models/\(Self.escapeRepo(repo))/auth-check", token: token))
        if (200..<300).contains(response.statusCode) { return .granted }
        let mapped = Self.error(response, repo: repo)
        if case .gated(_, _, let message) = mapped {
            // An invalid token on a gated repo looks like no token at all; whoami tells them apart.
            if token != nil, (try? await whoami(token: token)) == nil { return .invalidToken }
            let kind = (try? await repoInfo(repo))?.gate
            return .gated(kind: kind == HubGateKind.none ? .auto : (kind ?? .auto), message: message)
        }
        if response.statusCode == 401 || response.statusCode == 404 {
            if token != nil, (try? await whoami(token: token)) == nil { return .invalidToken }
            return .notFoundOrPrivate
        }
        throw mapped ?? HubError.http(status: response.statusCode, message: nil)
    }

    // MARK: Revisions and files

    /// The commit sha a branch/tag/sha points at on the Hub.
    public func resolveCommit(repo: String, revision: String) async throws -> String {
        let (data, response) = try await send(request(path: "api/models/\(Self.escapeRepo(repo))/revision/\(Self.escapeSegment(revision))"))
        try await checkWithToken(response, repo: repo, revision: revision)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String, HubCacheLayout.isCommitHash(sha) else {
            throw HubError.invalidResponse("revision \(revision) of \(repo)")
        }
        return sha
    }

    /// Every file in the repo at `commit` (recursive, all pages).
    public func listFiles(repo: String, commit: String) async throws -> [HubRepoFile] {
        var next: URL? = url(path: "api/models/\(Self.escapeRepo(repo))/tree/\(Self.escapeSegment(commit))",
                             query: [URLQueryItem(name: "recursive", value: "true"), URLQueryItem(name: "expand", value: "false")])
        var files: [HubRepoFile] = []
        while let pageURL = next {
            var req = URLRequest(url: pageURL)
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await send(req)
            try await checkWithToken(response, repo: repo, revision: commit)
            guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw HubError.invalidResponse("file list of \(repo)")
            }
            files += entries.compactMap(Self.parseTreeEntry)
            next = Self.nextLink(response.value(forHTTPHeaderField: "Link"))
        }
        return files
    }

    static func parseTreeEntry(_ e: [String: Any]) -> HubRepoFile? {
        guard e["type"] as? String == "file", let path = e["path"] as? String,
              let oid = e["oid"] as? String else { return nil }
        let size = (e["size"] as? NSNumber)?.int64Value ?? 0
        let xet = e["xetHash"] as? String
        if let lfs = e["lfs"] as? [String: Any], let sha = lfs["oid"] as? String {
            return HubRepoFile(path: path, size: (lfs["size"] as? NSNumber)?.int64Value ?? size, blobID: oid, lfsSHA256: sha, xetHash: xet)
        }
        return HubRepoFile(path: path, size: size, blobID: oid, xetHash: xet)
    }

    /// Parses an RFC 8288 `Link` header for `rel="next"`.
    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") {
            let pieces = part.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = pieces.first, first.hasPrefix("<"), first.hasSuffix(">"),
                  pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\"" }) else { continue }
            return URL(string: String(first.dropFirst().dropLast()))
        }
        return nil
    }

    // MARK: HTTP plumbing

    func url(path: String, query: [URLQueryItem] = []) -> URL {
        var s = endpoint.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        var comps = URLComponents(string: s + path)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    func request(path: String, token: String?? = .none) -> URLRequest {
        var req = URLRequest(url: url(path: path))
        let t: String? = token ?? self.token
        if let t { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return req
    }

    static func resolvePath(repo: String, revision: String, path: String) -> String {
        "\(escapeRepo(repo))/resolve/\(escapeSegment(revision))/\(escapePath(path))"
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(HubSession.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse("not HTTP") }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HubError.from(error)
        }
    }

    static func error(_ response: HTTPURLResponse, repo: String?, path: String? = nil, revision: String? = nil) -> HubError? {
        HubError.from(status: response.statusCode,
                      errorCode: response.value(forHTTPHeaderField: "X-Error-Code"),
                      errorMessage: response.value(forHTTPHeaderField: "X-Error-Message"),
                      retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                      repo: repo, path: path, revision: revision)
    }

    static func check(_ response: HTTPURLResponse, repo: String?, path: String? = nil, revision: String? = nil) throws {
        if let e = error(response, repo: repo, path: path, revision: revision) { throw e }
    }

    /// Like `check`, but a 401 with a token set is checked against whoami so a bad token is reported as such.
    func checkWithToken(_ response: HTTPURLResponse, repo: String, path: String? = nil, revision: String? = nil) async throws {
        guard let e = Self.error(response, repo: repo, path: path, revision: revision) else { return }
        if response.statusCode == 401, let token, (try? await whoami(token: token)) == nil { throw HubError.invalidToken }
        throw e
    }

    static func escapeRepo(_ repo: String) -> String {
        repo.split(separator: "/", omittingEmptySubsequences: false).map { escapeSegment(String($0)) }.joined(separator: "/")
    }
    static func escapePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { escapeSegment(String($0)) }.joined(separator: "/")
    }
    static func escapeSegment(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Licence ids as Hugging Face cards spell them → canonical reference pages.
enum HubLicenseCatalog {
    static let spdx: [String: String] = [
        "apache-2.0": "Apache-2.0", "mit": "MIT", "bsd-2-clause": "BSD-2-Clause", "bsd-3-clause": "BSD-3-Clause",
        "cc0-1.0": "CC0-1.0", "cc-by-4.0": "CC-BY-4.0", "cc-by-sa-4.0": "CC-BY-SA-4.0", "cc-by-nc-4.0": "CC-BY-NC-4.0",
        "cc-by-nc-sa-4.0": "CC-BY-NC-SA-4.0", "cc-by-nc-nd-4.0": "CC-BY-NC-ND-4.0", "cc-by-nd-4.0": "CC-BY-ND-4.0",
        "cc-by-3.0": "CC-BY-3.0", "cc-by-nc-3.0": "CC-BY-NC-3.0", "gpl-3.0": "GPL-3.0-only", "gpl-2.0": "GPL-2.0-only",
        "lgpl-3.0": "LGPL-3.0-only", "agpl-3.0": "AGPL-3.0-only", "mpl-2.0": "MPL-2.0", "unlicense": "Unlicense",
        "openrail": "OpenRAIL", "bigscience-openrail-m": "BigScience-OpenRAIL-M", "creativeml-openrail-m": "CreativeML-OpenRAIL-M",
    ]
    static func spdxID(for id: String?) -> String? { id.flatMap { spdx[$0.lowercased()] } }
    static func url(for id: String?) -> URL? {
        guard let spdxID = spdxID(for: id) else { return nil }
        return URL(string: "https://spdx.org/licenses/\(spdxID).html")
    }
}

/// Shared URLSession for Hub API calls. Strips `Authorization` when a redirect leaves the host,
/// so the token never reaches a CDN.
enum HubSession {
    static let userAgent = "Encore (macOS)"

    static let api: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            HubSession.redirect(from: task.originalRequest, to: request)
        }
    }

    static func redirect(from original: URLRequest?, to request: URLRequest) -> URLRequest {
        var request = request
        if original?.url?.host != request.url?.host {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
