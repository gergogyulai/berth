import Foundation

/// A configured SMB share. Everything that is persisted about a share lives here;
/// runtime state (mounted, stale, …) lives in `ShareRuntime`.
public struct Share: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    /// Ordered list of addresses to try. The first reachable (and allowed) address wins.
    public var addresses: [ServerAddress]
    public var shareName: String
    public var auth: AuthMode
    public var username: String
    public var domain: String
    public var icon: ShareIcon
    public var groupID: UUID?
    public var mountLocation: MountLocation
    public var autoMount: AutoMount
    public var options: MountOptions
    public var networkRule: NetworkRule
    public var wakeOnLAN: WakeOnLANConfig
    public var pinToSidebar: Bool
    public var applyVolumeIcon: Bool
    public var notes: String

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        addresses: [ServerAddress] = [ServerAddress()],
        shareName: String = "",
        auth: AuthMode = .registered,
        username: String = "",
        domain: String = "",
        icon: ShareIcon = .default,
        groupID: UUID? = nil,
        mountLocation: MountLocation = .automatic,
        autoMount: AutoMount = .off,
        options: MountOptions = MountOptions(),
        networkRule: NetworkRule = NetworkRule(),
        wakeOnLAN: WakeOnLANConfig = WakeOnLANConfig(),
        pinToSidebar: Bool = false,
        applyVolumeIcon: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.addresses = addresses
        self.shareName = shareName
        self.auth = auth
        self.username = username
        self.domain = domain
        self.icon = icon
        self.groupID = groupID
        self.mountLocation = mountLocation
        self.autoMount = autoMount
        self.options = options
        self.networkRule = networkRule
        self.wakeOnLAN = wakeOnLAN
        self.pinToSidebar = pinToSidebar
        self.applyVolumeIcon = applyVolumeIcon
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, addresses, shareName, auth, username, domain, icon, groupID
        case mountLocation, autoMount, options, networkRule, wakeOnLAN, pinToSidebar, applyVolumeIcon, notes
    }

    // Lenient decoding: every field except the id is optional on disk, so configs written
    // by older (or newer) versions of Berth keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Share()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try c.value(.displayName, default: d.displayName)
        addresses = try c.value(.addresses, default: d.addresses)
        shareName = try c.value(.shareName, default: d.shareName)
        auth = try c.value(.auth, default: d.auth)
        username = try c.value(.username, default: d.username)
        domain = try c.value(.domain, default: d.domain)
        icon = try c.value(.icon, default: d.icon)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        mountLocation = try c.value(.mountLocation, default: d.mountLocation)
        autoMount = try c.value(.autoMount, default: d.autoMount)
        options = try c.value(.options, default: d.options)
        networkRule = try c.value(.networkRule, default: d.networkRule)
        wakeOnLAN = try c.value(.wakeOnLAN, default: d.wakeOnLAN)
        pinToSidebar = try c.value(.pinToSidebar, default: d.pinToSidebar)
        applyVolumeIcon = try c.value(.applyVolumeIcon, default: d.applyVolumeIcon)
        notes = try c.value(.notes, default: d.notes)
    }

    /// The name shown everywhere in the UI.
    public var name: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !shareName.isEmpty { return shareName }
        return primaryHost.isEmpty ? "Untitled Share" : primaryHost
    }

    public var primaryHost: String { addresses.first?.host ?? "" }

    /// `host/share` for compact display.
    public var locationSummary: String {
        let host = primaryHost.isEmpty ? "—" : primaryHost
        return shareName.isEmpty ? host : "\(host)/\(shareName)"
    }

    /// A short, stable, CLI-friendly identifier, e.g. "nas-media".
    public var slug: String { Share.slugify(name) }

    public static func slugify(_ string: String) -> String {
        let folded = string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "share" : out
    }

    /// Whether the share has the minimum information needed to attempt a mount.
    public var isComplete: Bool {
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty
            && addresses.contains { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }
            && (auth != .registered || !username.isEmpty)
    }
}

public enum AuthMode: String, Codable, CaseIterable, Sendable {
    /// Username + password from the Keychain.
    case registered
    /// Connect as the server's guest account.
    case guest
    /// Anonymous / null session (no credentials at all).
    case anonymous

    public var title: String {
        switch self {
        case .registered: "Registered User"
        case .guest: "Guest"
        case .anonymous: "Anonymous"
        }
    }
}

public enum AutoMount: String, Codable, CaseIterable, Sendable {
    /// Only mount when asked.
    case off
    /// Mount once when Berth launches (typically at login).
    case atLaunch
    /// Mount whenever the network rules allow it, and keep it mounted.
    case whenAvailable

    public var title: String {
        switch self {
        case .off: "Manually"
        case .atLaunch: "At Login"
        case .whenAvailable: "Whenever Available"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Only mount when you ask."
        case .atLaunch: "Mount once when Berth starts."
        case .whenAvailable: "Mount as soon as an allowed network appears, and keep it mounted."
        }
    }
}

public enum MountLocation: Codable, Hashable, Sendable {
    /// Let macOS pick a mount point under /Volumes.
    case automatic
    /// Mount into a specific (user-writable) folder.
    case custom(path: String)

    public var customPath: String? {
        if case .custom(let path) = self { return path }
        return nil
    }
}

public struct MountOptions: Codable, Hashable, Sendable {
    /// Soft mount: I/O to an unresponsive server fails with an error instead of hanging.
    public var softMount: Bool = true
    /// Hide the volume from the Finder sidebar and desktop (MNT_DONTBROWSE).
    public var hideFromFinder: Bool = false
    public var readOnly: Bool = false
    /// Disallow set-uid binaries and device files (MNT_NOSUID | MNT_NODEV).
    public var noSetUID: Bool = true
    /// Use a fresh SMB session even if one to this server already exists.
    public var forceNewSession: Bool = false
    /// Performance preset applied to the server's nsmb.conf section.
    public var preset: PerformancePreset? = nil

    public init(softMount: Bool = true, hideFromFinder: Bool = false, readOnly: Bool = false,
                noSetUID: Bool = true, forceNewSession: Bool = false, preset: PerformancePreset? = nil) {
        self.softMount = softMount
        self.hideFromFinder = hideFromFinder
        self.readOnly = readOnly
        self.noSetUID = noSetUID
        self.forceNewSession = forceNewSession
        self.preset = preset
    }

    enum CodingKeys: String, CodingKey { case softMount, hideFromFinder, readOnly, noSetUID, forceNewSession, preset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        softMount = try c.value(.softMount, default: true)
        hideFromFinder = try c.value(.hideFromFinder, default: false)
        readOnly = try c.value(.readOnly, default: false)
        noSetUID = try c.value(.noSetUID, default: true)
        forceNewSession = try c.value(.forceNewSession, default: false)
        preset = try? c.decodeIfPresent(PerformancePreset.self, forKey: .preset)
    }
}

public struct WakeOnLANConfig: Codable, Hashable, Sendable {
    public var enabled: Bool = false
    /// Hardware address, any common notation (aa:bb:cc:dd:ee:ff, aa-bb-…, aabb.ccdd.eeff).
    public var macAddress: String = ""
    /// Directed broadcast address; empty means 255.255.255.255.
    public var broadcastAddress: String = ""
    /// How long to wait for the host to come up after sending the magic packet.
    public var wakeTimeout: TimeInterval = 45

    public init(enabled: Bool = false, macAddress: String = "", broadcastAddress: String = "", wakeTimeout: TimeInterval = 45) {
        self.enabled = enabled
        self.macAddress = macAddress
        self.broadcastAddress = broadcastAddress
        self.wakeTimeout = wakeTimeout
    }

    enum CodingKeys: String, CodingKey { case enabled, macAddress, broadcastAddress, wakeTimeout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.value(.enabled, default: false)
        macAddress = try c.value(.macAddress, default: "")
        broadcastAddress = try c.value(.broadcastAddress, default: "")
        wakeTimeout = try c.value(.wakeTimeout, default: 45)
    }

    public var isUsable: Bool { enabled && WakeOnLAN.parseMAC(macAddress) != nil }
}

public struct ShareGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String

    public init(id: UUID = UUID(), name: String, symbol: String = "folder") {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `defaultValue` when the key is missing or malformed.
    func value<T: Decodable>(_ key: Key, default defaultValue: T) throws -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue
    }
}
