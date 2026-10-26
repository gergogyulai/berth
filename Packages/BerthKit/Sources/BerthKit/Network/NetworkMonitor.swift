import Foundation
import Network
import CoreWLAN
import CoreLocation
import os

/// Watches the network and publishes debounced `NetworkSnapshot`s.
///
/// Combines `NWPathMonitor` (interfaces, metered, constrained), CoreWLAN (SSID, needs Location
/// permission) and a `getifaddrs` scan for Tailscale's tunnel interface.
@MainActor
@Observable
public final class NetworkMonitor {
    public private(set) var snapshot: NetworkSnapshot = .unknown
    public private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined

    /// Called on the main actor when the network fingerprint changes (after debouncing).
    @ObservationIgnored public var onChange: ((_ old: NetworkSnapshot, _ new: NetworkSnapshot) -> Void)?

    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.berth.network")
    @ObservationIgnored private var latestPath: NWPath?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let locationDelegate = LocationDelegate()
    @ObservationIgnored private lazy var locationManager = CLLocationManager()
    @ObservationIgnored private let log = Logger(subsystem: "app.berth", category: "network")

    public init() {}

    public func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.pathChanged(path) }
        }
        pathMonitor.start(queue: queue)

        locationDelegate.onChange = { [weak self] status in
            Task { @MainActor in
                self?.locationAuthorization = status
                self?.scheduleRefresh(delay: .zero)
            }
        }
        locationManager.delegate = locationDelegate
        locationAuthorization = locationManager.authorizationStatus

        // NWPathMonitor does not fire for every change we care about (e.g. joining another SSID on
        // the same interface, or the Tailscale tunnel getting its address a moment after coming
        // up), so also poll cheaply.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.scheduleRefresh(delay: .zero)
            }
        }
    }

    public func stop() {
        pathMonitor.cancel()
        pollTask?.cancel()
        debounceTask?.cancel()
    }

    /// Ask for Location permission so the Wi-Fi network name becomes readable.
    public func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    public var canReadSSID: Bool {
        locationAuthorization == .authorizedAlways || locationAuthorization == .authorized
    }

    /// Re-read everything now (e.g. after wake).
    public func refreshNow() { scheduleRefresh(delay: .zero) }

    private func pathChanged(_ path: NWPath) {
        latestPath = path
        // Interfaces flap during transitions (Wi-Fi → Ethernet, VPN reconnects). Wait for things
        // to settle before telling anyone.
        scheduleRefresh(delay: .milliseconds(1500))
    }

    private func scheduleRefresh(delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let path = self.latestPath
            let new = await Task.detached { NetworkMonitor.buildSnapshot(path: path) }.value
            guard !Task.isCancelled else { return }
            self.apply(new)
        }
    }

    private func apply(_ new: NetworkSnapshot) {
        let old = snapshot
        guard old != new else { return }
        snapshot = new
        // The first snapshot is the baseline, not a change.
        if old != .unknown, old.fingerprint != new.fingerprint {
            log.info("Network changed: \(new.summary, privacy: .public)")
            onChange?(old, new)
        }
    }

    nonisolated static func buildSnapshot(path: NWPath?) -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        if let path {
            snap.isOnline = path.status == .satisfied
            snap.isExpensive = path.isExpensive
            snap.isConstrained = path.isConstrained
            snap.interfaceNames = path.availableInterfaces.map(\.name)
            snap.usesWired = path.usesInterfaceType(.wiredEthernet)
            snap.usesWiFi = path.usesInterfaceType(.wifi)
            if let first = path.availableInterfaces.first {
                snap.primary = switch first.type {
                case .wifi: .wifi
                case .wiredEthernet: .wired
                case .cellular: .cellular
                case .loopback: .loopback
                default: .other
                }
            }
        }
        if snap.usesWiFi || snap.primary == nil {
            let ssid = CWWiFiClient.shared().interface()?.ssid()
            snap.ssid = (ssid?.isEmpty == false) ? ssid : nil
            if snap.ssid != nil { snap.usesWiFi = true }
        }
        let interfaces = InterfaceScanner.scan()
        snap.tailscale = InterfaceScanner.tailscaleStatus(from: interfaces)
        snap.vpnInterfaces = interfaces
            .filter { $0.isUp && ($0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("ppp")) && $0.hasRoutableAddress }
            .map(\.name)
            .uniqued()
        // NWPathMonitor can briefly report unsatisfied while a VPN takes over the default route;
        // treat a live tailnet as connectivity for our purposes.
        if !snap.isOnline && snap.tailscale.isUp { snap.isOnline = true }
        return snap
    }
}

private final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var onChange: ((CLAuthorizationStatus) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?(manager.authorizationStatus)
    }
}

/// Thin wrapper over getifaddrs.
public enum InterfaceScanner {
    public struct Entry: Sendable {
        public var name: String
        public var address: String
        public var isIPv4: Bool
        public var isUp: Bool
        public var isTailscale: Bool
        public var hasRoutableAddress: Bool { !address.hasPrefix("fe80") && !address.hasPrefix("169.254") }
    }

    public static func scan() -> [Entry] {
        var result: [Entry] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(ifa.ifa_flags)
            let up = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }
            let isTS: Bool
            if family == AF_INET, let v4 = IPv4Address(address) {
                isTS = AddressClassifier.isTailscaleIPv4(v4)
            } else if let v6 = IPv6Address(address) {
                isTS = AddressClassifier.isTailscaleIPv6(v6)
            } else {
                isTS = false
            }
            result.append(Entry(name: name, address: address, isIPv4: family == AF_INET, isUp: up, isTailscale: isTS))
        }
        return result
    }

    public static func tailscaleStatus(from entries: [Entry]) -> TailscaleStatus {
        let ts = entries.filter { $0.isTailscale && $0.isUp }
        let installed = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/tailscale")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tailscale")
        return TailscaleStatus(
            isUp: !ts.isEmpty,
            interface: ts.first?.name,
            addresses: ts.sorted { $0.isIPv4 && !$1.isIPv4 }.map(\.address),
            isInstalled: installed || !ts.isEmpty
        )
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
