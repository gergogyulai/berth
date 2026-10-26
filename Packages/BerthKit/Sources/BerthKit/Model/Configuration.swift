import Foundation

/// Everything Berth persists (except secrets, which live in the Keychain).
public struct Configuration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = Configuration.currentVersion
    public var shares: [Share] = []
    public var groups: [ShareGroup] = []
    public var homeNetworks: HomeNetworks = HomeNetworks()
    public var preferences: Preferences = Preferences()

    public init(shares: [Share] = [], groups: [ShareGroup] = [], homeNetworks: HomeNetworks = HomeNetworks(),
                preferences: Preferences = Preferences()) {
        self.shares = shares
        self.groups = groups
        self.homeNetworks = homeNetworks
        self.preferences = preferences
    }

    enum CodingKeys: String, CodingKey { case version, shares, groups, homeNetworks, preferences }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.value(.version, default: Configuration.currentVersion)
        shares = try c.value(.shares, default: [])
        groups = try c.value(.groups, default: [])
        homeNetworks = try c.value(.homeNetworks, default: HomeNetworks())
        preferences = try c.value(.preferences, default: Preferences())
    }

    public func share(id: UUID) -> Share? { shares.first { $0.id == id } }

    public func group(id: UUID?) -> ShareGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    public func shares(inGroup id: UUID?) -> [Share] { shares.filter { $0.groupID == id } }

    /// Finds a share by id, slug, display name or share name (case-insensitive). Used by the CLI,
    /// AppleScript and Shortcuts.
    public func resolveShare(_ query: String) -> Share? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let uuid = UUID(uuidString: q), let s = share(id: uuid) { return s }
        let lower = q.lowercased()
        return shares.first { $0.slug == lower }
            ?? shares.first { $0.name.lowercased() == lower }
            ?? shares.first { $0.shareName.lowercased() == lower }
            ?? shares.first { $0.slug == Share.slugify(q) }
    }

    public func resolveGroup(_ query: String) -> ShareGroup? {
        let lower = query.lowercased()
        return groups.first { $0.name.lowercased() == lower } ?? groups.first { Share.slugify($0.name) == Share.slugify(query) }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    // Connection
    public var autoMountEnabled: Bool = true
    public var probeInterval: TimeInterval = 20
    public var probeTimeout: TimeInterval = 5
    public var mountTimeout: TimeInterval = 30
    public var maxRetryDelay: TimeInterval = 300
    public var forceUnmountStale: Bool = true
    /// How long a mount may be unresponsive before it is force-unmounted and remounted.
    public var staleGracePeriod: TimeInterval = 15
    public var unmountBeforeSleep: Bool = false
    public var remountAfterWake: Bool = true
    public var pauseOnExpensiveNetworks: Bool = true
    public var pauseOnConstrainedNetworks: Bool = true
    public var waitForTailscale: Bool = true

    // Notifications
    public var notifyOnConnect: Bool = false
    public var notifyOnDisconnect: Bool = true
    public var notifyOnAuthFailure: Bool = true
    public var notifyOnStale: Bool = true

    // Hotkeys
    public var mountAllHotKey: HotKey? = nil
    public var unmountAllHotKey: HotKey? = nil

    public init() {}

    enum CodingKeys: String, CodingKey {
        case autoMountEnabled, probeInterval, probeTimeout, mountTimeout, maxRetryDelay, forceUnmountStale
        case staleGracePeriod, unmountBeforeSleep, remountAfterWake, pauseOnExpensiveNetworks
        case pauseOnConstrainedNetworks, waitForTailscale, notifyOnConnect, notifyOnDisconnect
        case notifyOnAuthFailure, notifyOnStale, mountAllHotKey, unmountAllHotKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        autoMountEnabled = try c.value(.autoMountEnabled, default: d.autoMountEnabled)
        probeInterval = try c.value(.probeInterval, default: d.probeInterval)
        probeTimeout = try c.value(.probeTimeout, default: d.probeTimeout)
        mountTimeout = try c.value(.mountTimeout, default: d.mountTimeout)
        maxRetryDelay = try c.value(.maxRetryDelay, default: d.maxRetryDelay)
        forceUnmountStale = try c.value(.forceUnmountStale, default: d.forceUnmountStale)
        staleGracePeriod = try c.value(.staleGracePeriod, default: d.staleGracePeriod)
        unmountBeforeSleep = try c.value(.unmountBeforeSleep, default: d.unmountBeforeSleep)
        remountAfterWake = try c.value(.remountAfterWake, default: d.remountAfterWake)
        pauseOnExpensiveNetworks = try c.value(.pauseOnExpensiveNetworks, default: d.pauseOnExpensiveNetworks)
        pauseOnConstrainedNetworks = try c.value(.pauseOnConstrainedNetworks, default: d.pauseOnConstrainedNetworks)
        waitForTailscale = try c.value(.waitForTailscale, default: d.waitForTailscale)
        notifyOnConnect = try c.value(.notifyOnConnect, default: d.notifyOnConnect)
        notifyOnDisconnect = try c.value(.notifyOnDisconnect, default: d.notifyOnDisconnect)
        notifyOnAuthFailure = try c.value(.notifyOnAuthFailure, default: d.notifyOnAuthFailure)
        notifyOnStale = try c.value(.notifyOnStale, default: d.notifyOnStale)
        mountAllHotKey = try c.decodeIfPresent(HotKey.self, forKey: .mountAllHotKey)
        unmountAllHotKey = try c.decodeIfPresent(HotKey.self, forKey: .unmountAllHotKey)
    }
}

/// A global keyboard shortcut (Carbon virtual key code + modifier flags).
public struct HotKey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    public var carbonModifiers: UInt32
    /// Pre-rendered display string, e.g. "⌃⌥⌘M".
    public var display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }
}
