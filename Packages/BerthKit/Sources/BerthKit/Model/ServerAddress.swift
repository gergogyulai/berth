import Foundation
import Network

/// One way of reaching a server: a LAN IP, a Bonjour name, a Tailscale MagicDNS name…
public struct ServerAddress: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var host: String
    /// Non-standard SMB port; nil means 445.
    public var port: Int?
    public var kind: AddressKind

    public init(id: UUID = UUID(), host: String = "", port: Int? = nil, kind: AddressKind = .automatic) {
        self.id = id
        self.host = host
        self.port = port
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, host, port, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.value(.host, default: "")
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        kind = try c.value(.kind, default: .automatic)
    }

    public var trimmedHost: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.lowercased().hasPrefix("smb://") { h.removeFirst(6) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }

    public var effectivePort: Int { port ?? 445 }

    /// The resolved classification of this address, taking `.automatic` into account.
    public var resolvedKind: AddressKind.Resolved {
        switch kind {
        case .lan: .lan
        case .tailscale: .tailscale
        case .automatic: AddressClassifier.classify(trimmedHost)
        }
    }

    /// Human readable, including a non-default port.
    public var display: String {
        if let port, port != 445 { return "\(trimmedHost):\(port)" }
        return trimmedHost
    }
}

public enum AddressKind: String, Codable, CaseIterable, Sendable {
    case automatic, lan, tailscale

    public enum Resolved: String, Sendable {
        case lan, tailscale
    }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .lan: "Local Network"
        case .tailscale: "Tailscale"
        }
    }
}

public enum AddressClassifier {
    /// 100.64.0.0/10 — the CGNAT range Tailscale hands out.
    public static func isTailscaleIPv4(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        return bytes.count == 4 && bytes[0] == 100 && (bytes[1] & 0xC0) == 64
    }

    /// fd7a:115c:a1e0::/48 — Tailscale's ULA range.
    public static func isTailscaleIPv6(_ address: IPv6Address) -> Bool {
        let b = [UInt8](address.rawValue)
        return b.count == 16 && b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
    }

    public static func classify(_ host: String) -> AddressKind.Resolved {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if let v4 = IPv4Address(h) { return isTailscaleIPv4(v4) ? .tailscale : .lan }
        if let v6 = IPv6Address(h) { return isTailscaleIPv6(v6) ? .tailscale : .lan }
        // MagicDNS names: machine.tailnet-name.ts.net (and the legacy beta.tailscale.net).
        if h.hasSuffix(".ts.net") || h.hasSuffix(".beta.tailscale.net") { return .tailscale }
        return .lan
    }
}
