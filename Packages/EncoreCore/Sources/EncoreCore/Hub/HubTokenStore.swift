import Foundation
import Security

/// Where the token in use came from.
public enum HubTokenSource: String, Sendable, Hashable {
    /// `HF_TOKEN` in the environment (read-only; wins, as in huggingface_hub).
    case environment
    case keychain
    /// Taken from the standard token file because the Keychain was empty or held a different token;
    /// Encore's Keychain copy was updated to match.
    case tokenFile
}

/// The user's Hugging Face access token: kept in the Keychain and mirrored to the standard token
/// file (`HF_TOKEN_PATH`, default `$HF_HOME/token`, mode 0600) so the Python helper and the `hf`
/// CLI see the same login.
///
/// The shared file wins: when it holds a token, that's the one Encore uses, and the Keychain copy is
/// brought in line with it. Without the file, the Keychain copy is used (and the file isn't rewritten).
/// After `signOutOfEncoreOnly()`, Encore ignores the file until the user signs in again in Encore
/// (`save`) or chooses to use the shared token again (`clearEncoreOnlySignOut`); that choice is kept
/// in the Keychain, so it survives relaunches.
public struct HubTokenStore: Sendable {
    public static let defaultService = "dev.abdeen.Encore.huggingface"

    public var service: String
    public var account: String
    /// nil → `EncorePaths.huggingFaceTokenFile`, evaluated on each call so env changes apply.
    public var tokenFileOverride: URL?
    /// Honor `HF_TOKEN` from the environment. Off in tests.
    public var readsEnvironment: Bool

    public init(service: String = HubTokenStore.defaultService, account: String = "huggingface.co",
                tokenFile: URL? = nil, readsEnvironment: Bool = true) {
        self.service = service
        self.account = account
        self.tokenFileOverride = tokenFile
        self.readsEnvironment = readsEnvironment
    }

    public static let standard = HubTokenStore()

    /// An isolated store for snapshots and tests: its own Keychain service, a token file under `directory`,
    /// no `HF_TOKEN`. Never sees the user's real token.
    public static func snapshot(in directory: URL) -> HubTokenStore {
        HubTokenStore(service: defaultService + ".snapshot", tokenFile: directory.appendingPathComponent("hf-token"), readsEnvironment: false)
    }

    public var tokenFile: URL { tokenFileOverride ?? EncorePaths.huggingFaceTokenFile }

    /// The token to use, and where it came from. `HF_TOKEN` wins; then, unless the user signed out of
    /// Encore only, the shared token file (copied into the Keychain when the Keychain copy differs); then
    /// the Keychain copy.
    public func current() -> (token: String, source: HubTokenSource)? {
        if readsEnvironment, let env = Self.clean(ProcessInfo.processInfo.environment["HF_TOKEN"]) {
            return (env, .environment)
        }
        if isSignedOutOfEncoreOnly { return nil }
        let stored = try? keychainToken()
        if let file = fileToken() {
            if stored == file { return (file, .keychain) }
            try? setKeychainToken(file)
            return (file, .tokenFile)
        }
        if let stored { return (stored, .keychain) }
        return nil
    }

    public func token() -> String? { current()?.token }

    /// Signs in: stores the token in the Keychain, writes the token file (0600), and ends an Encore-only sign-out.
    public func save(_ token: String) throws {
        guard let token = Self.clean(token) else { return try clear() }
        try setKeychainToken(token)
        try writeTokenFile(token)
        try clearEncoreOnlySignOut()
    }

    /// Signs out everywhere: removes the token from the Keychain and deletes the token file, which also
    /// signs out the `hf` command-line tool and anything else that reads it.
    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HubError.keychain(status) }
        let file = tokenFile
        if FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch { throw HubError.fileSystem(error.localizedDescription) }
        }
        try clearEncoreOnlySignOut()
    }

    // MARK: Encore-only sign-out

    /// Signs Encore out but leaves the shared token file (and so the `hf` tool) alone: removes Encore's
    /// Keychain copy and records that Encore should ignore the file until the user signs in again here.
    public func signOutOfEncoreOnly() throws {
        try removeKeychainToken()
        let status = SecItemAdd(signedOutMarkerAddQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw HubError.keychain(status) }
    }

    /// True after `signOutOfEncoreOnly()` until `save`, `clear` or `clearEncoreOnlySignOut`. While true,
    /// `current()` ignores the token file and the Python helper isn't given it either.
    public var isSignedOutOfEncoreOnly: Bool {
        var query = signedOutMarkerQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Ends an Encore-only sign-out, so the shared token file is used again.
    public func clearEncoreOnlySignOut() throws {
        let status = SecItemDelete(signedOutMarkerQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HubError.keychain(status) }
    }

    /// A separate Keychain item (no secret in it) under the same service: its presence is the state.
    private var signedOutMarkerQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account + ".signed-out-of-encore"]
    }

    private var signedOutMarkerAddQuery: [String: Any] {
        var add = signedOutMarkerQuery
        add[kSecValueData as String] = Data("1".utf8)
        add[kSecAttrLabel as String] = "Encore: signed out of Hugging Face in Encore only"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return add
    }

    /// True when Encore's Keychain item holds a token (the token file and `HF_TOKEN` aren't consulted).
    public var hasKeychainToken: Bool { (try? keychainToken()) != nil }

    /// Removes Encore's Keychain item only. The token file is left alone: it belongs to the machine and the
    /// `hf` command-line tool (`clear()` removes both).
    public func removeKeychainToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HubError.keychain(status) }
    }

    // MARK: Keychain

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func keychainToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw HubError.keychain(status) }
        return Self.clean(String(data: data, encoding: .utf8))
    }

    func setKeychainToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw HubError.keychain(update) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Hugging Face access token (Encore)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw HubError.keychain(status) }
    }

    // MARK: Token file

    func fileToken() -> String? {
        guard let data = try? Data(contentsOf: tokenFile) else { return nil }
        return Self.clean(String(data: data, encoding: .utf8))
    }

    func writeTokenFile(_ token: String) throws {
        let file = tokenFile
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Write a 0600 temp file next to it, then rename, so the token is never world-readable.
            let tmp = file.deletingLastPathComponent().appendingPathComponent(".token.\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: tmp.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw HubError.fileSystem("Couldn't write \(file.path)")
            }
            if rename(tmp.path, file.path) != 0 {
                let err = String(cString: strerror(errno))
                try? fm.removeItem(at: tmp)
                throw HubError.fileSystem("Couldn't write \(file.path): \(err)")
            }
        } catch let error as HubError { throw error } catch { throw HubError.fileSystem(error.localizedDescription) }
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
