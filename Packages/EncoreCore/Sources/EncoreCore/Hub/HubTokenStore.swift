import Foundation
import Security

/// Where the token in use came from.
public enum HubTokenSource: String, Sendable, Hashable {
    /// `HF_TOKEN` in the environment (read-only; wins, as in huggingface_hub).
    case environment
    case keychain
    /// Adopted from the standard token file because the Keychain was empty.
    case tokenFile
}

/// The user's Hugging Face access token: kept in the Keychain and mirrored to the standard token
/// file (`HF_TOKEN_PATH`, default `$HF_HOME/token`, mode 0600) so the Python helper and the `hf`
/// CLI see the same login. A token already in the file is adopted when the Keychain is empty.
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

    /// The token to use, and where it came from. Adopts the token file into the Keychain if needed.
    public func current() -> (token: String, source: HubTokenSource)? {
        if readsEnvironment, let env = Self.clean(ProcessInfo.processInfo.environment["HF_TOKEN"]) {
            return (env, .environment)
        }
        if let stored = try? keychainToken() { return (stored, .keychain) }
        if let file = fileToken() {
            try? setKeychainToken(file)
            return (file, .tokenFile)
        }
        return nil
    }

    public func token() -> String? { current()?.token }

    /// Stores the token in the Keychain and writes the token file (0600).
    public func save(_ token: String) throws {
        guard let token = Self.clean(token) else { return try clear() }
        try setKeychainToken(token)
        try writeTokenFile(token)
    }

    /// Removes the token from the Keychain and deletes the token file.
    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HubError.keychain(status) }
        let file = tokenFile
        if FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch { throw HubError.fileSystem(error.localizedDescription) }
        }
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
