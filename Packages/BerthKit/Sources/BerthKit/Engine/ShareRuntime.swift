import Foundation

/// Live, observable state for one share. Owned and mutated by `ShareCoordinator`.
@MainActor
@Observable
public final class ShareRuntime: Identifiable {
    public let id: UUID

    public internal(set) var state: ShareState = .disconnected
    public internal(set) var mountPoint: String?
    /// The address the current (or last) connection used.
    public internal(set) var activeAddress: String?
    public internal(set) var activeAddressKind: AddressKind.Resolved?
    public internal(set) var lastError: String?
    public internal(set) var lastProbeLatency: Duration?
    public internal(set) var lastProbeAt: Date?
    /// Recent probe latencies in milliseconds, oldest first (for the sparkline).
    public internal(set) var latencyHistory: [Double] = []
    public internal(set) var connectedSince: Date?
    public internal(set) var attempt: Int = 0
    public internal(set) var nextRetryAt: Date?
    /// The user's (or auto-mount's) intent. Reconnect logic only acts while this is true.
    public internal(set) var wantsMounted = false
    /// Set when the user mounted explicitly despite the network rule; cleared on unmount.
    public internal(set) var overridesRule = false

    // Engine bookkeeping (not observed).
    @ObservationIgnored var operation: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored var probeInFlight = false
    @ObservationIgnored var staleSince: Date?
    @ObservationIgnored var expectingUnmount = false
    @ObservationIgnored var ejectRequestedAt: Date?
    @ObservationIgnored var remountAfterWake = false
    @ObservationIgnored var wakeAttempted = false

    init(id: UUID) { self.id = id }

    public var isBusy: Bool { operation != nil || state.isBusy }

    /// Berth is actively trying to get this share mounted (connecting, retrying, or waiting for
    /// Tailscale). Toggling it should cancel rather than start another attempt.
    public var isTrying: Bool {
        guard wantsMounted, !state.isMounted else { return false }
        return isBusy || nextRetryAt != nil || state == .tailscaleDown
    }

    func recordLatency(_ latency: Duration) {
        lastProbeLatency = latency
        lastProbeAt = Date()
        latencyHistory.append(latency.inMilliseconds)
        if latencyHistory.count > 40 { latencyHistory.removeFirst(latencyHistory.count - 40) }
    }
}
