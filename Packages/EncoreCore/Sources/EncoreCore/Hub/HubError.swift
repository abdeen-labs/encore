import Foundation

/// How a Hugging Face repo is gated. `auto` grants access as soon as the user accepts on the
/// model page; `manual` waits for the repo owner to approve the request.
public enum HubGateKind: String, Codable, Sendable, Hashable {
    case none, auto, manual
}

/// Everything that can go wrong talking to the Hub or the local cache, typed so the UI can react
/// (open the gate flow, ask for a token, offer a retry) rather than just print a message.
public enum HubError: LocalizedError, Sendable, Hashable {
    /// The repo is gated and the current token (or anonymous access) hasn't been granted.
    /// `kind` is filled in when it could be determined. Open `HubService.modelPageURL(repo)`
    /// so the user can accept, then retry.
    case gated(repo: String, kind: HubGateKind?, message: String)
    /// The Hub answers 401 without a gate for both missing and private repos; they can't be told apart.
    case repoNotFoundOrPrivate(repo: String)
    case revisionNotFound(repo: String, revision: String)
    case fileNotFound(repo: String, path: String)
    /// The stored token was rejected by `whoami`.
    case invalidToken
    case forbidden(repo: String?, message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case http(status: Int, message: String?)
    case offline
    case network(code: Int, message: String)
    /// A downloaded file didn't match the size or hash the Hub published for it.
    case integrity(repo: String, path: String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case invalidResponse(String)
    case fileSystem(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .gated(let repo, let kind, let message):
            let how = kind == .manual ? "request access" : "accept the conditions"
            return "\(repo) is gated: \(how) on its Hugging Face page, then try again. (\(message))"
        case .repoNotFoundOrPrivate(let repo):
            return "\(repo) doesn't exist on Hugging Face, or it's private and your token can't see it."
        case .revisionNotFound(let repo, let rev): return "\(repo) has no revision \"\(rev)\"."
        case .fileNotFound(let repo, let path): return "\(repo) has no file \(path)."
        case .invalidToken: return "Hugging Face rejected the access token. Check it in Settings."
        case .forbidden(let repo, let message):
            return repo.map { "Access to \($0) was refused: \(message)" } ?? "Access refused: \(message)"
        case .rateLimited(let after):
            if let after { return "Hugging Face is rate-limiting requests. Try again in \(Int(after.rounded(.up))) s." }
            return "Hugging Face is rate-limiting requests. Try again shortly."
        case .server(let status, let message): return "Hugging Face server error \(status)\(message.map { ": \($0)" } ?? "")."
        case .http(let status, let message): return "Unexpected response \(status) from Hugging Face\(message.map { ": \($0)" } ?? "")."
        case .offline: return "You're offline."
        case .network(_, let message): return message
        case .integrity(let repo, let path): return "\(path) from \(repo) was corrupted in transit. Try again."
        case .insufficientDiskSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough disk space: needs \(f.string(fromByteCount: needed)), \(f.string(fromByteCount: available)) free."
        case .invalidResponse(let what): return "Hugging Face sent an unexpected response (\(what))."
        case .fileSystem(let message): return message
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(text)"
        }
    }

    /// The repo whose gate must be accepted, when this is a gate error.
    public var gatedRepo: String? {
        if case .gated(let repo, _, _) = self { return repo }
        return nil
    }

    /// Worth retrying automatically (transient network or server trouble).
    public var isTransient: Bool {
        switch self {
        case .network, .server, .rateLimited: return true
        default: return false
        }
    }

    /// Maps a Hub HTTP response to an error, or nil for success/redirects. Pure, so it's unit-tested.
    /// The `X-Error-Code` header is the signal; the status code alone is ambiguous on the Hub.
    public static func from(status: Int, errorCode: String?, errorMessage: String?, retryAfter: String? = nil,
                            repo: String?, path: String? = nil, revision: String? = nil) -> HubError? {
        guard status >= 400 else { return nil }
        let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch errorCode {
        case "GatedRepo":
            return .gated(repo: repo ?? "?", kind: nil, message: message ?? "Access is restricted.")
        case "RepoNotFound":
            return .repoNotFoundOrPrivate(repo: repo ?? "?")
        case "RevisionNotFound":
            return .revisionNotFound(repo: repo ?? "?", revision: revision ?? "?")
        case "EntryNotFound":
            return .fileNotFound(repo: repo ?? "?", path: path ?? "?")
        default: break
        }
        switch status {
        case 401:
            if let repo { return .repoNotFoundOrPrivate(repo: repo) }
            return .invalidToken
        case 403: return .forbidden(repo: repo, message: message ?? "forbidden")
        case 404:
            if let repo, let path { return .fileNotFound(repo: repo, path: path) }
            if let repo { return .repoNotFoundOrPrivate(repo: repo) }
            return .http(status: 404, message: message)
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap { TimeInterval($0) })
        case 500...599: return .server(status: status, message: message)
        default: return .http(status: status, message: message)
        }
    }

    /// Maps a transport error. Cancellation is passed through as `CancellationError` by callers.
    public static func from(_ error: URLError) -> HubError {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        default: return .network(code: error.errorCode, message: error.localizedDescription)
        }
    }
}
