import Foundation
import Security

/// Per-share passwords in the user's login Keychain.
///
/// Items are generic passwords keyed by the share's UUID, so each macOS user — and each share —
/// gets its own credential, and nothing leaks into the configuration file (which may be synced).
public enum Keychain {
    public static let service = "app.berth.smb-password"

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .status(let s): (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
        }
    }

    private static func baseQuery(_ shareID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: shareID.uuidString,
        ]
    }

    public static func password(for shareID: UUID) -> String? {
        var query = baseQuery(shareID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasPassword(for shareID: UUID) -> Bool {
        var query = baseQuery(shareID)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Saves (or replaces) the password. `label` is what Keychain Access shows.
    public static func setPassword(_ password: String, for shareID: UUID, label: String, server: String, username: String) throws {
        var attributes = details(label: label, server: server, username: username)
        attributes[kSecValueData as String] = Data(password.utf8)
        let status = SecItemUpdate(baseQuery(shareID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(shareID)
            add.merge(attributes) { $1 }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    /// Brings a saved password's name up to date with its share, leaving the password alone. Keychain
    /// prompts show this name. Attributes can be read without a prompt, so an item that's already
    /// right is never written to.
    public static func updateDetails(for shareID: UUID, label: String, server: String, username: String) {
        var query = baseQuery(shareID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let current = item as? [String: Any] else { return }
        let wanted = details(label: label, server: server, username: username)
        let isCurrent = wanted.allSatisfy { key, value in (current[key] as? String) == (value as? String) }
        guard !isCurrent else { return }
        SecItemUpdate(baseQuery(shareID) as CFDictionary, wanted as CFDictionary)
    }

    private static func details(label: String, server: String, username: String) -> [String: Any] {
        [
            kSecAttrLabel as String: "Berth: \(label)",
            kSecAttrDescription as String: "SMB share password",
            kSecAttrComment as String: "\(username)@\(server)",
        ]
    }

    public static func deletePassword(for shareID: UUID) {
        SecItemDelete(baseQuery(shareID) as CFDictionary)
    }

    /// Looks for a password Finder saved for this server ("Remember this password in my keychain").
    /// Used when importing shares. May trigger a Keychain access prompt.
    public static func finderPassword(server: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
