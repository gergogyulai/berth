import Foundation

/// Where a share is allowed to mount, and over which addresses.
public struct NetworkRule: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Mount on any network, trying addresses in order.
        case anywhere
        /// Only mount while on a trusted (home) network.
        case trustedOnly
        /// On a trusted network use any address (LAN first); elsewhere only Tailscale addresses.
        case trustedOrTailscale
        /// Never use LAN addresses; always go through Tailscale.
        case tailscaleOnly

        public var title: String {
            switch self {
            case .anywhere: "On Any Network"
            case .trustedOnly: "Only on Home Networks"
            case .trustedOrTailscale: "Home Networks, Otherwise via Tailscale"
            case .tailscaleOnly: "Only via Tailscale"
            }
        }
    }

    public var mode: Mode = .anywhere
    /// Wi-Fi network names that count as "home" for this share. Empty = use the global home networks.
    public var trustedNetworks: [String] = []

    public init(mode: Mode = .anywhere, trustedNetworks: [String] = []) {
        self.mode = mode
        self.trustedNetworks = trustedNetworks
    }

    enum CodingKeys: String, CodingKey { case mode, trustedNetworks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.value(.mode, default: .anywhere)
        trustedNetworks = try c.value(.trustedNetworks, default: [])
    }
}

/// The outcome of evaluating a share's rule against the current network.
public enum RuleDecision: Equatable, Sendable {
    /// Try these addresses, in order.
    case allowed([ServerAddress])
    /// Not allowed on this network.
    case blocked(String)
    /// Allowed, but only over Tailscale, and the tailnet is down.
    case needsTailscale
}

public enum RuleEvaluator {
    public static func evaluate(
        share: Share,
        network: NetworkSnapshot,
        homeNetworks: HomeNetworks
    ) -> RuleDecision {
        let usable = share.addresses.filter { !$0.trimmedHost.isEmpty }
        let lan = usable.filter { $0.resolvedKind == .lan }
        let tailnet = usable.filter { $0.resolvedKind == .tailscale }

        let trusted = share.networkRule.trustedNetworks.isEmpty
            ? homeNetworks.isHome(network)
            : homeNetworks.isHome(network, overridingSSIDs: share.networkRule.trustedNetworks)

        func tailnetOnly() -> RuleDecision {
            if tailnet.isEmpty { return .blocked("No Tailscale address configured") }
            return network.tailscale.isUp ? .allowed(tailnet) : .needsTailscale
        }

        let decision: RuleDecision
        switch share.networkRule.mode {
        case .anywhere:
            decision = .allowed(usable)
        case .trustedOnly:
            decision = trusted ? .allowed(usable) : .blocked("Not on a home network")
        case .trustedOrTailscale:
            decision = trusted ? .allowed(lan + tailnet) : tailnetOnly()
        case .tailscaleOnly:
            decision = tailnetOnly()
        }

        // When the tailnet is down, drop Tailscale addresses from the candidate list; if nothing
        // is left, surface that as its own condition rather than as "host unreachable".
        if case .allowed(let addresses) = decision, !network.tailscale.isUp {
            let remaining = addresses.filter { $0.resolvedKind != .tailscale }
            if remaining.isEmpty, !addresses.isEmpty { return .needsTailscale }
            return .allowed(remaining)
        }
        return decision
    }
}

/// The user's definition of "home".
public struct HomeNetworks: Codable, Hashable, Sendable {
    public var ssids: [String] = []
    /// Treat any wired Ethernet connection as being at home (SSID is unavailable on Ethernet).
    public var wiredIsHome: Bool = false

    public init(ssids: [String] = [], wiredIsHome: Bool = false) {
        self.ssids = ssids
        self.wiredIsHome = wiredIsHome
    }

    enum CodingKeys: String, CodingKey { case ssids, wiredIsHome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ssids = try c.value(.ssids, default: [])
        wiredIsHome = try c.value(.wiredIsHome, default: false)
    }

    public func isHome(_ network: NetworkSnapshot, overridingSSIDs: [String]? = nil) -> Bool {
        let list = overridingSSIDs ?? ssids
        if wiredIsHome && network.usesWired { return true }
        guard let ssid = network.ssid else { return false }
        return list.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame }
    }
}
