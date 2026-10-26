import Foundation

/// An immutable picture of the network at one moment.
public struct NetworkSnapshot: Equatable, Sendable {
    public enum Interface: String, Sendable, Codable {
        case wifi, wired, cellular, loopback, other
    }

    public var isOnline: Bool
    /// Primary interface type (the one the default route uses).
    public var primary: Interface?
    public var interfaceNames: [String]
    public var usesWired: Bool
    public var usesWiFi: Bool
    /// Wi-Fi network name. Requires Location Services permission on modern macOS.
    public var ssid: String?
    /// Hotspot / cellular / user-marked metered network.
    public var isExpensive: Bool
    /// Low Data Mode.
    public var isConstrained: Bool
    public var tailscale: TailscaleStatus
    /// Any utun/ipsec/ppp interface with an address (generic VPN detection).
    public var vpnInterfaces: [String]

    public init(isOnline: Bool = false, primary: Interface? = nil, interfaceNames: [String] = [], usesWired: Bool = false,
                usesWiFi: Bool = false, ssid: String? = nil, isExpensive: Bool = false, isConstrained: Bool = false,
                tailscale: TailscaleStatus = TailscaleStatus(), vpnInterfaces: [String] = []) {
        self.isOnline = isOnline
        self.primary = primary
        self.interfaceNames = interfaceNames
        self.usesWired = usesWired
        self.usesWiFi = usesWiFi
        self.ssid = ssid
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.tailscale = tailscale
        self.vpnInterfaces = vpnInterfaces
    }

    public static let unknown = NetworkSnapshot()

    /// Two snapshots with the same fingerprint describe the same "network". A fingerprint change is
    /// what triggers reconnect logic (Wi-Fi → Ethernet, VPN up/down, new SSID…).
    public var fingerprint: String {
        [
            isOnline ? "on" : "off",
            primary?.rawValue ?? "-",
            usesWired ? "wired" : "",
            usesWiFi ? "wifi:\(ssid ?? "?")" : "",
            tailscale.isUp ? "ts:\(tailscale.addresses.sorted().joined(separator: ","))" : "ts:down",
            "vpn:\(vpnInterfaces.sorted().joined(separator: ","))",
        ].joined(separator: "|")
    }

    public var summary: String {
        guard isOnline else { return "Offline" }
        var parts: [String] = []
        if usesWired { parts.append("Ethernet") }
        if usesWiFi { parts.append(ssid.map { "Wi-Fi “\($0)”" } ?? "Wi-Fi") }
        if parts.isEmpty, let primary { parts.append(primary.rawValue.capitalized) }
        if tailscale.isUp { parts.append("Tailscale") }
        if isExpensive { parts.append("metered") }
        if isConstrained { parts.append("Low Data Mode") }
        return parts.joined(separator: " · ")
    }
}

public struct TailscaleStatus: Equatable, Sendable {
    /// Whether a tunnel interface currently holds a tailnet address.
    public var isUp: Bool = false
    public var interface: String? = nil
    public var addresses: [String] = []
    /// Whether the Tailscale app appears to be installed at all.
    public var isInstalled: Bool = false

    public init(isUp: Bool = false, interface: String? = nil, addresses: [String] = [], isInstalled: Bool = false) {
        self.isUp = isUp
        self.interface = interface
        self.addresses = addresses
        self.isInstalled = isInstalled
    }

    public var title: String {
        if isUp { return addresses.first.map { "Connected (\($0))" } ?? "Connected" }
        return isInstalled ? "Not connected" : "Not installed"
    }
}
