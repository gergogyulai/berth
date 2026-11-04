@_exported import BerthSMB
import Foundation
import Security

/// Constants and types shared by the app and the Berth Cloud File Provider extension.
public enum BerthCloud {
    /// Bundle name of the embedded File Provider extension.
    public static let extensionName = "BerthCloud.appex"

    /// XPC service the extension vends on every domain's root item.
    public static let controlServiceName = "app.berth.cloud.control"

    /// Whether this copy of Berth carries the cloud volume extension.
    public static var isExtensionEmbedded: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appending(path: extensionName).path)
    }

    public static func domainIdentifier(for shareID: UUID) -> String { shareID.uuidString }

    public static func shareID(forDomain identifier: String) -> UUID? { UUID(uuidString: identifier) }
}

/// Everything the extension needs to reach a share. Pushed by the app whenever it mounts the
/// share (or its settings change) and persisted by the extension, so it keeps working while
/// Berth isn't running. Contains no secrets.
public struct CloudDomainConfiguration: Codable, Sendable, Equatable {
    public struct Endpoint: Codable, Sendable, Equatable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public var shareID: UUID
    public var displayName: String
    /// The address Berth picked for the current network (reachable, allowed by the rules).
    public var endpoint: Endpoint
    /// Other addresses, tried in order when the preferred one stops answering.
    public var fallbacks: [Endpoint]
    public var shareName: String
    public var auth: AuthMode
    public var username: String
    public var domain: String
    public var readOnly: Bool
    public var requireSigning: Bool
    public var requireEncryption: Bool
    public var tuning: SMBClient.Tuning
    /// Bumped on every push so the extension notices changes and reconnects.
    public var generation: Date

    public init(shareID: UUID, displayName: String, endpoint: Endpoint, fallbacks: [Endpoint], shareName: String,
                auth: AuthMode, username: String, domain: String, readOnly: Bool, requireSigning: Bool,
                requireEncryption: Bool, tuning: SMBClient.Tuning, generation: Date = Date()) {
        self.shareID = shareID
        self.displayName = displayName
        self.endpoint = endpoint
        self.fallbacks = fallbacks
        self.shareName = shareName
        self.auth = auth
        self.username = username
        self.domain = domain
        self.readOnly = readOnly
        self.requireSigning = requireSigning
        self.requireEncryption = requireEncryption
        self.tuning = tuning
        self.generation = generation
    }

    /// SMB client configuration for one endpoint.
    public func clientConfiguration(endpoint: Endpoint, password: String?) -> SMBClient.Configuration {
        let credentials: SMBCredentials = switch auth {
        case .registered: .user(name: username, password: password ?? "", domain: domain)
        case .guest: .guest
        case .anonymous: .anonymous
        }
        return SMBClient.Configuration(
            host: endpoint.host, port: endpoint.port, share: shareName, credentials: credentials,
            workstation: CloudDomainConfiguration.workstationName, connectTimeout: .seconds(8),
            requestTimeout: .seconds(30), requireSigning: requireSigning, requireEncryption: requireEncryption,
            tuning: tuning)
    }

    /// NetBIOS-ish name of this Mac, shown in the server's session list.
    public static var workstationName: String {
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "BERTH"
        return String(host.uppercased().prefix(15))
    }
}

extension SMBClient.Tuning {
    /// SMB client tuning for a share's performance preset and the kind of link in use.
    public static func recommended(preset: PerformancePreset?, link: AddressKind.Resolved?) -> SMBClient.Tuning {
        switch preset {
        case .fastLAN?:
            var t = SMBClient.Tuning.lan
            t.ioSize = 4 << 20
            t.ioDepth = 8
            return t
        case .tailscaleWAN?:
            return .wan
        case .compatibility?:
            var t = SMBClient.Tuning()
            t.ioSize = 64 * 1024
            t.ioDepth = 8
            t.targetCredits = 128
            t.directoryBufferSize = 64 * 1024
            return t
        case nil:
            return link == .tailscale ? .wan : .lan
        }
    }
}

/// What the extension reports back to the app (inspector, diagnostics).
public struct CloudDomainStatus: Codable, Sendable, Equatable {
    public var configured: Bool
    public var connected: Bool
    public var summary: String?
    public var lastError: String?
    public var indexedItems: Int
    public var pendingChanges: Int

    public init(configured: Bool, connected: Bool, summary: String?, lastError: String?, indexedItems: Int, pendingChanges: Int) {
        self.configured = configured
        self.connected = connected
        self.summary = summary
        self.lastError = lastError
        self.indexedItems = indexedItems
        self.pendingChanges = pendingChanges
    }
}

/// The XPC interface the extension exports to the Berth app.
@objc public protocol BerthCloudControl {
    /// Stores the configuration (JSON `CloudDomainConfiguration`) and password, and reconnects
    /// if anything changed. Replies with an error message, or nil.
    func configure(_ configuration: Data, password: String?, reply: @escaping @Sendable (String?) -> Void)

    /// Directories ("/"-separated share paths) whose listings changed on the server.
    func markDirty(_ paths: [String], recursive: Bool, reply: @escaping @Sendable () -> Void)

    /// JSON `CloudDomainStatus`.
    func status(_ reply: @escaping @Sendable (Data?) -> Void)
}

/// Passwords the extension keeps for its domains, in its own keychain items.
///
/// The app pushes the password over XPC; the extension stores it so it can reconnect on its own.
/// No keychain sharing (and so no provisioning-profile-only entitlement) is needed.
public enum CloudSecrets {
    static let service = "app.berth.cloud.password"

    private static func query(_ domainID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: domainID,
        ]
    }

    public static func password(for domainID: String) -> String? {
        var q = query(domainID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String?, for domainID: String) {
        guard let password else {
            SecItemDelete(query(domainID) as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(domainID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(domainID)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Berth Cloud"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Errors

extension MountError {
    /// Maps a BerthSMB failure onto the kinds the coordinator's state machine understands, so
    /// the custom client behaves exactly like NetFS from the UI's point of view.
    public static func from(_ error: SMBError) -> MountError {
        switch error {
        case .status(let status) where status.isAuthenticationFailure:
            return MountError(kind: .authentication, code: Int32(bitPattern: status.rawValue), message: status.message)
        case .status(let status) where status.isPasswordExpired:
            return MountError(kind: .passwordExpired, code: Int32(bitPattern: status.rawValue), message: status.message)
        case .status(let status) where status == .badNetworkName:
            return MountError(kind: .shareNotFound, code: Int32(bitPattern: status.rawValue), message: status.message)
        case .status(let status) where status == .accessDenied || status == .networkAccessDenied:
            return MountError(kind: .authentication, code: Int32(bitPattern: status.rawValue),
                              message: "The server refused access to the share for this account.")
        case .status(let status):
            return MountError(kind: .other, code: Int32(bitPattern: status.rawValue), message: status.message)
        case .connectionFailed(let code, let message):
            return MountError(kind: code == ETIMEDOUT ? .timedOut : .hostUnreachable, code: code, message: message)
        case .disconnected(let reason):
            return MountError(kind: .hostUnreachable, code: ECONNRESET, message: "The connection was lost (\(reason)).")
        case .timedOut:
            return MountError(kind: .timedOut, code: ETIMEDOUT, message: error.description)
        case .cancelled:
            return MountError(kind: .cancelled, code: ECANCELED, message: error.description)
        case .unsupported(let message):
            return MountError(kind: .invalidConfiguration, message: message)
        case .malformed, .signatureMismatch, .localIO, .invalidArgument:
            return MountError(kind: .other, message: error.description)
        }
    }
}
