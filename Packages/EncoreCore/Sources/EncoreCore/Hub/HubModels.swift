import Foundation

/// The signed-in Hugging Face account, from `whoami`.
public struct HubAccount: Codable, Sendable, Hashable {
    public var name: String
    public var fullName: String?
    public var avatarURL: URL?
    /// `read`, `write` or `fineGrained`.
    public var tokenRole: String?
    /// The token's own display name on huggingface.co.
    public var tokenName: String?

    public init(name: String, fullName: String? = nil, avatarURL: URL? = nil, tokenRole: String? = nil, tokenName: String? = nil) {
        self.name = name; self.fullName = fullName; self.avatarURL = avatarURL; self.tokenRole = tokenRole; self.tokenName = tokenName
    }
}

/// What the details view shows about a repo, from `GET /api/models/{id}` (works anonymously, gated or not).
public struct HubRepoInfo: Codable, Sendable, Hashable {
    public var id: String
    public var commit: String?
    public var gate: HubGateKind
    public var isPrivate: Bool
    /// License id as the card declares it (`apache-2.0`, `cc-by-nc-4.0`, `other`, …).
    public var licenseID: String?
    /// `license_name` from the card, set for custom (`other`) licenses.
    public var licenseName: String?
    /// `license_link` from the card, resolved to an absolute URL.
    public var licenseLink: URL?
    /// The text shown on the gate (`extra_gated_prompt`), often the license itself.
    public var gatePrompt: String?
    /// `extra_gated_description`.
    public var gateDescription: String?
    /// Every file in the repo at `commit`.
    public var files: [String]
    public var lastModified: Date?
    public var pageURL: URL

    public init(id: String, commit: String? = nil, gate: HubGateKind = .none, isPrivate: Bool = false, licenseID: String? = nil,
                licenseName: String? = nil, licenseLink: URL? = nil, gatePrompt: String? = nil, gateDescription: String? = nil,
                files: [String] = [], lastModified: Date? = nil, pageURL: URL) {
        self.id = id; self.commit = commit; self.gate = gate; self.isPrivate = isPrivate; self.licenseID = licenseID
        self.licenseName = licenseName; self.licenseLink = licenseLink; self.gatePrompt = gatePrompt
        self.gateDescription = gateDescription; self.files = files; self.lastModified = lastModified; self.pageURL = pageURL
    }
}

/// License text to display, with where it came from.
public struct HubLicenseText: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// A license file in the repo (path in repo).
        case repoFile(String)
        /// The gate prompt (`extra_gated_prompt`), shown when it carries the terms.
        case gatePrompt
        /// The "License" section of the model card.
        case modelCard
        /// The standard text of the declared license (SPDX id), from spdx.org.
        case standard(String)
        /// No text available; `url` (if any) points at the license.
        case none
    }
    public var source: Source
    public var text: String?
    /// Where to read the license in a browser: the card's link, the file on huggingface.co, or the SPDX page.
    public var url: URL?

    public init(source: Source, text: String?, url: URL?) { self.source = source; self.text = text; self.url = url }
}

/// Whether the current token (or anonymous access) can download a repo.
public enum HubAccess: Sendable, Hashable {
    case granted
    /// Not yet granted. For `manual` gates after a request, `message` says it's pending.
    case gated(kind: HubGateKind, message: String)
    case notFoundOrPrivate
    /// A token is set but huggingface.co rejects it.
    case invalidToken
}

/// One file in a repo at a commit, from the tree API (or huggingface_hub's `trees/<commit>.json`).
public struct HubRepoFile: Codable, Sendable, Hashable {
    public var path: String
    public var size: Int64
    /// The git blob sha1.
    public var blobID: String
    /// The LFS sha256, for LFS files.
    public var lfsSHA256: String?
    public var xetHash: String?

    public init(path: String, size: Int64, blobID: String, lfsSHA256: String? = nil, xetHash: String? = nil) {
        self.path = path; self.size = size; self.blobID = blobID; self.lfsSHA256 = lfsSHA256; self.xetHash = xetHash
    }

    public var isLFS: Bool { lfsSHA256 != nil }
    /// The blob's name in the cache: the LFS sha256 for LFS files, the git blob sha1 otherwise.
    public var etag: String { lfsSHA256 ?? blobID }
}
