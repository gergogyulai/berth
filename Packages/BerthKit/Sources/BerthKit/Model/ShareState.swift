import Foundation

/// The connection state of a single share, as shown in the UI.
public enum ShareState: Equatable, Sendable {
    case disconnected
    /// Mounting is held back by a rule or the network (metered, not home, offline…).
    case paused(PauseReason)
    /// A Wake-on-LAN packet was sent and Berth is waiting for the host to come up.
    case waking
    case connecting
    case mounted
    /// Mounted, but the server stopped answering probes.
    case stale
    /// A previously-working mount is being re-established.
    case reconnecting
    case unmounting
    case authFailed
    case hostUnreachable
    /// The share is only reachable via Tailscale and the tailnet is down.
    case tailscaleDown
    case failed

    public enum PauseReason: Equatable, Sendable {
        case offline
        case meteredNetwork
        case networkRule(String)
        case sleeping

        public var title: String {
            switch self {
            case .offline: "No network"
            case .meteredNetwork: "Paused on metered network"
            case .networkRule(let message): message
            case .sleeping: "Paused for sleep"
            }
        }
    }

    public var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .paused(let reason): reason.title
        case .waking: "Waking server…"
        case .connecting: "Connecting…"
        case .mounted: "Mounted"
        case .stale: "Not responding"
        case .reconnecting: "Reconnecting…"
        case .unmounting: "Unmounting…"
        case .authFailed: "Authentication failed"
        case .hostUnreachable: "Host unreachable"
        case .tailscaleDown: "Tailscale down"
        case .failed: "Failed"
        }
    }

    /// Short machine-friendly identifier (CLI, AppleScript, Shortcuts).
    public var code: String {
        switch self {
        case .disconnected: "disconnected"
        case .paused: "paused"
        case .waking: "waking"
        case .connecting: "connecting"
        case .mounted: "mounted"
        case .stale: "stale"
        case .reconnecting: "reconnecting"
        case .unmounting: "unmounting"
        case .authFailed: "auth-failed"
        case .hostUnreachable: "host-unreachable"
        case .tailscaleDown: "tailscale-down"
        case .failed: "failed"
        }
    }

    public var symbol: String {
        switch self {
        case .disconnected: "circle"
        case .paused: "pause.circle"
        case .waking: "power.circle"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath.circle"
        case .mounted: "checkmark.circle.fill"
        case .stale: "exclamationmark.circle.fill"
        case .unmounting: "eject.circle"
        case .authFailed: "key.slash"
        case .hostUnreachable: "network.slash"
        case .tailscaleDown: "point.3.filled.connected.trianglepath.dotted"
        case .failed: "xmark.circle.fill"
        }
    }

    public enum Tone: Sendable { case neutral, positive, busy, warning, negative }

    public var tone: Tone {
        switch self {
        case .disconnected, .paused: .neutral
        case .mounted: .positive
        case .waking, .connecting, .reconnecting, .unmounting: .busy
        case .stale, .tailscaleDown, .hostUnreachable: .warning
        case .authFailed, .failed: .negative
        }
    }

    public var isMounted: Bool { self == .mounted || self == .stale }
    public var isBusy: Bool { tone == .busy }
    public var isProblem: Bool { tone == .warning || tone == .negative }
}
