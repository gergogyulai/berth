import Foundation
import os

/// Events the app turns into notifications.
public enum CoordinatorEvent: Sendable {
    case mounted(Share, path: String, reconnected: Bool)
    case disconnected(Share, reason: String)
    case ejected(Share)
    case authFailed(Share, message: String)
    case stale(Share)
    case unreachable(Share, message: String)
}

public enum UnmountOutcome: Sendable, Equatable {
    case unmounted
    case notMounted
    case busy(String)
    case failed(String)
}

/// The brain: owns every share's runtime state and drives mounting, probing and reconnecting.
///
/// All state lives on the main actor. Anything that can block (NetFS, statfs on a dead mount,
/// unmount) runs on dedicated threads with timeouts, so the UI never hangs on a dead server.
@MainActor
@Observable
public final class ShareCoordinator {
    public let store: ConfigStore
    public let network: NetworkMonitor
    public let log: EventLog

    public private(set) var runtimes: [UUID: ShareRuntime] = [:]
    public private(set) var isSleeping = false
    public private(set) var hasStarted = false

    @ObservationIgnored public var onEvent: ((CoordinatorEvent) -> Void)?
    /// Runs after every successful mount (volume icon, sidebar pinning…). Errors are the hook's business.
    @ObservationIgnored public var postMountHook: ((Share, String) async -> Void)?
    /// Runs before an unmount Berth initiates (e.g. to unpin from the sidebar).
    @ObservationIgnored public var preUnmountHook: ((Share, String) -> Void)?

    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var diskSubscription: UUID?
    @ObservationIgnored private let power = PowerObserver()
    @ObservationIgnored private let logger = Logger(subsystem: "app.berth", category: "coordinator")

    private enum ConnectReason: String {
        case user, launch, network, retry, reconnect, wake, availability

        var isAutomatic: Bool { self != .user }
    }

    public init(store: ConfigStore, network: NetworkMonitor, log: EventLog) {
        self.store = store
        self.network = network
        self.log = log
        syncRuntimes()
    }

    private var prefs: Preferences { store.config.preferences }

    // MARK: - Lifecycle

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        network.onChange = { [weak self] old, new in self?.networkChanged(from: old, to: new) }
        network.start()

        diskSubscription = DiskWatcher.shared.subscribe { [weak self] event in
            Task { @MainActor in self?.handleDiskEvent(event) }
        }

        power.handler = { [weak self] event, done in
            guard let self else { done(); return }
            switch event {
            case .willSleep: self.systemWillSleep(completion: done)
            case .didWake: self.systemDidWake()
            }
        }
        power.start()

        store.onExternalChange = { [weak self] _ in
            self?.syncRuntimes()
            self?.log.add(.info, "Configuration updated from another Mac")
        }

        adoptExistingMounts()
        log.add(.info, "Berth started")

        Task {
            // Give the network monitor a moment to produce its first snapshot.
            for _ in 0..<20 where network.snapshot == .unknown {
                try? await Task.sleep(for: .milliseconds(100))
            }
            log.add(.info, "Network: \(network.snapshot.summary)")
            if prefs.autoMountEnabled {
                for share in store.config.shares where share.autoMount != .off {
                    let rt = runtime(for: share.id)
                    guard !rt.state.isMounted else { continue }
                    rt.wantsMounted = true
                    connect(share.id, reason: .launch)
                }
            }
            startHealthChecks()
        }
    }

    /// Unmount nothing, just stop timers (used at quit; mounts survive the app).
    public func stop() {
        healthTask?.cancel()
        for rt in runtimes.values {
            rt.retryTask?.cancel()
            rt.operation?.cancel()
        }
        network.stop()
        if let diskSubscription { DiskWatcher.shared.unsubscribe(diskSubscription) }
    }

    /// Keeps `runtimes` in step with the configured shares.
    public func syncRuntimes() {
        let ids = Set(store.config.shares.map(\.id))
        for id in ids where runtimes[id] == nil { runtimes[id] = ShareRuntime(id: id) }
        for id in runtimes.keys where !ids.contains(id) {
            runtimes[id]?.retryTask?.cancel()
            runtimes[id]?.operation?.cancel()
            runtimes.removeValue(forKey: id)
        }
    }

    public func runtime(for id: UUID) -> ShareRuntime {
        if let rt = runtimes[id] { return rt }
        let rt = ShareRuntime(id: id)
        runtimes[id] = rt
        return rt
    }

    public func share(_ id: UUID) -> Share? { store.config.share(id: id) }

    // MARK: - Public commands

    public func mount(_ id: UUID) {
        guard let share = share(id) else { return }
        let rt = runtime(for: id)
        rt.wantsMounted = true
        rt.attempt = 0
        if case .blocked = RuleEvaluator.evaluate(share: share, network: network.snapshot, homeNetworks: store.config.homeNetworks) {
            rt.overridesRule = true
        }
        if rt.state == .mounted { return }
        rt.retryTask?.cancel()
        connect(id, reason: .user)
    }

    @discardableResult
    public func unmount(_ id: UUID, force: Bool = false) async -> UnmountOutcome {
        let rt = runtime(for: id)
        rt.wantsMounted = false
        rt.overridesRule = false
        rt.retryTask?.cancel()
        rt.retryTask = nil
        rt.nextRetryAt = nil
        rt.attempt = 0
        if rt.operation != nil, !rt.state.isMounted {
            // A connect is in flight; it will notice the changed intent and back out.
            rt.operation?.cancel()
        }
        return await performUnmount(id, force: force, reason: "Unmounted")
    }

    public func toggle(_ id: UUID) {
        let rt = runtime(for: id)
        if rt.state.isMounted || rt.isTrying {
            Task { await unmount(id) }
        } else {
            mount(id)
        }
    }

    public func mountAll(groupID: UUID? = nil, onlyGroup: Bool = false) {
        for share in store.config.shares where !onlyGroup || share.groupID == groupID {
            mount(share.id)
        }
    }

    @discardableResult
    public func unmountAll(groupID: UUID? = nil, onlyGroup: Bool = false, force: Bool = false) async -> [UUID: UnmountOutcome] {
        let ids = store.config.shares
            .filter { !onlyGroup || $0.groupID == groupID }
            .map(\.id)
        // Start all unmounts at once (each one is mostly waiting on DiskArbitration), then collect.
        let tasks = ids.map { id in (id, Task { await self.unmount(id, force: force) }) }
        var result: [UUID: UnmountOutcome] = [:]
        for (id, task) in tasks { result[id] = await task.value }
        return result
    }

    /// Force-unmounts (if needed) and mounts again from scratch.
    public func reconnect(_ id: UUID) {
        guard let share = share(id) else { return }
        let rt = runtime(for: id)
        rt.wantsMounted = true
        rt.attempt = 0
        rt.retryTask?.cancel()
        log.add(.info, "Reconnect requested", share: share)
        Task {
            if rt.state.isMounted {
                _ = await performUnmount(id, force: true, reason: "Reconnecting", isInternal: true)
            }
            connect(id, reason: .user)
        }
    }

    /// The change-credentials flow: unmount, store the new secret, remount if it was in use.
    public func updateCredentials(_ id: UUID, auth: AuthMode, username: String, domain: String, password: String?) async throws {
        guard var share = share(id) else { return }
        let rt = runtime(for: id)
        let shouldRemount = rt.wantsMounted || rt.state.isMounted || rt.state == .authFailed

        if rt.state.isMounted {
            _ = await performUnmount(id, force: true, reason: "Updating credentials", isInternal: true)
        }
        share.auth = auth
        share.username = username
        share.domain = domain
        if auth == .registered, let password {
            try Keychain.setPassword(password, for: id, label: share.name, server: share.primaryHost, username: username)
        } else if auth != .registered {
            Keychain.deletePassword(for: id)
        }
        store.upsert(share)
        log.add(.info, "Credentials updated", share: share)

        if shouldRemount {
            rt.wantsMounted = true
            rt.attempt = 0
            rt.retryTask?.cancel()
            connect(id, reason: .user)
        } else if rt.state == .authFailed {
            rt.state = .disconnected
        }
    }

    /// Call after a share was edited; reconciles the runtime with the new definition.
    public func shareDidChange(_ id: UUID) {
        syncRuntimes()
        guard let share = share(id) else { return }
        let rt = runtime(for: id)
        if !rt.state.isMounted, rt.state != .disconnected, !rt.isBusy {
            // Retry immediately with the new settings.
            rt.retryTask?.cancel()
            rt.attempt = 0
            if rt.wantsMounted { connect(id, reason: .user) } else { rt.state = .disconnected }
        }
        if share.autoMount == .whenAvailable, prefs.autoMountEnabled, !rt.wantsMounted, !rt.state.isMounted {
            if case .allowed = RuleEvaluator.evaluate(share: share, network: network.snapshot, homeNetworks: store.config.homeNetworks) {
                rt.wantsMounted = true
                connect(id, reason: .availability)
            }
        }
    }

    /// Removes a share, unmounting it first if asked.
    public func remove(_ id: UUID, unmountFirst: Bool) async {
        if unmountFirst, runtime(for: id).state.isMounted {
            await unmount(id, force: true)
        }
        runtimes[id]?.retryTask?.cancel()
        runtimes[id]?.operation?.cancel()
        store.removeShare(id: id)
        syncRuntimes()
    }

    // MARK: - Connecting

    private func connect(_ id: UUID, reason: ConnectReason) {
        let rt = runtime(for: id)
        guard rt.operation == nil else { return }
        rt.retryTask?.cancel()
        rt.retryTask = nil
        rt.nextRetryAt = nil
        rt.operation = Task { [weak self] in
            await self?.performConnect(id, reason: reason)
            self?.runtimes[id]?.operation = nil
        }
    }

    private func performConnect(_ id: UUID, reason: ConnectReason) async {
        guard let share = share(id) else { return }
        let rt = runtime(for: id)
        guard rt.wantsMounted else { return }

        guard share.isComplete else {
            rt.state = .failed
            rt.lastError = "The share is missing a server, share name or user name."
            return
        }

        // Already mounted (by us earlier, by Finder, or by another tool)?
        if let entry = MountTable.find(share, knownMountPoint: rt.mountPoint, in: MountTable.smbMounts()) {
            adopt(entry, for: share, announce: reason == .user)
            return
        }

        if isSleeping {
            rt.state = .paused(.sleeping)
            return
        }

        let snapshot = network.snapshot
        guard snapshot.isOnline else {
            rt.state = .paused(.offline)
            rt.lastError = nil
            return // a network change will bring us back
        }
        if reason.isAutomatic && !rt.overridesRule {
            if prefs.pauseOnExpensiveNetworks && snapshot.isExpensive || prefs.pauseOnConstrainedNetworks && snapshot.isConstrained {
                if rt.state != .paused(.meteredNetwork) {
                    log.add(.info, "Not mounting on a metered network", share: share)
                }
                rt.state = .paused(.meteredNetwork)
                return
            }
        }

        // Which addresses may we use here?
        var candidates: [ServerAddress]
        switch RuleEvaluator.evaluate(share: share, network: snapshot, homeNetworks: store.config.homeNetworks) {
        case .allowed(let list):
            candidates = list
        case .blocked(let message):
            if reason.isAutomatic && !rt.overridesRule {
                rt.state = .paused(.networkRule(message))
                return
            }
            // Manual mount: honor the request but still skip Tailscale addresses if it's down.
            candidates = share.addresses.filter { !$0.trimmedHost.isEmpty && (snapshot.tailscale.isUp || $0.resolvedKind != .tailscale) }
        case .needsTailscale:
            rt.state = .tailscaleDown
            rt.lastError = "This share is reachable only through Tailscale, which is not connected."
            if rt.attempt == 0 { log.add(.warning, "Waiting for Tailscale", share: share) }
            if !prefs.waitForTailscale { scheduleRetry(id) }
            return
        }
        guard !candidates.isEmpty else {
            rt.state = .failed
            rt.lastError = "No usable address."
            return
        }

        rt.state = (reason == .reconnect || reason == .wake) ? .reconnecting : .connecting

        // Find the first address that answers on the SMB port.
        var chosen = await firstReachable(candidates, share: share)
        guard !Task.isCancelled, rt.wantsMounted else { return finishCancelled(rt) }

        if chosen == nil, share.wakeOnLAN.isUsable, !rt.wakeAttempted {
            rt.wakeAttempted = true
            rt.state = .waking
            do {
                try WakeOnLAN.wake(mac: share.wakeOnLAN.macAddress, broadcast: share.wakeOnLAN.broadcastAddress)
                log.add(.info, "Sent Wake-on-LAN packet to \(share.wakeOnLAN.macAddress)", share: share)
            } catch {
                log.add(.warning, "Wake-on-LAN failed: \(error.localizedDescription)", share: share)
            }
            let deadline = Date().addingTimeInterval(share.wakeOnLAN.wakeTimeout)
            while chosen == nil, Date() < deadline, !Task.isCancelled, rt.wantsMounted {
                try? await Task.sleep(for: .seconds(3))
                chosen = await firstReachable(candidates, share: share, quiet: true)
            }
            guard !Task.isCancelled, rt.wantsMounted else { return finishCancelled(rt) }
            rt.state = .connecting
        }

        guard let (address, latency) = chosen else {
            rt.state = .hostUnreachable
            let names = candidates.map(\.display).joined(separator: ", ")
            rt.lastError = "No response from \(names)."
            if rt.attempt == 0 {
                log.add(.warning, "Host unreachable (\(names))", share: share)
                onEvent?(.unreachable(share, message: rt.lastError ?? ""))
            }
            scheduleRetry(id)
            return
        }
        rt.activeAddress = address.display
        rt.activeAddressKind = address.resolvedKind
        rt.recordLatency(latency)

        // Credentials.
        var password: String?
        if share.auth == .registered {
            password = Keychain.password(for: id)
            if password == nil {
                rt.state = .authFailed
                rt.lastError = "No password is saved for this share."
                log.add(.error, "No password in Keychain", share: share)
                onEvent?(.authFailed(share, message: rt.lastError!))
                return
            }
        }

        guard let url = SMBURL.make(address: address, share: share.shareName, auth: share.auth,
                                    username: share.username, domain: share.domain) else {
            rt.state = .failed
            rt.lastError = "Could not build a URL for \(address.display)."
            return
        }

        log.add(.debug, "Mounting \(url.absoluteString) (\(reason.rawValue))", share: share)
        let request = MountRequest(
            url: url,
            mountPoint: share.mountLocation.customPath.map { ($0 as NSString).expandingTildeInPath },
            username: share.auth == .registered ? (share.domain.isEmpty ? share.username : "\(share.domain);\(share.username)") : (share.auth == .anonymous ? "" : nil),
            password: share.auth == .registered ? password : (share.auth == .anonymous ? "" : nil),
            guest: share.auth == .guest,
            options: share.options,
            timeout: .seconds(prefs.mountTimeout)
        )

        do {
            let path = try await Mounter.mount(request)
            guard rt.wantsMounted else {
                // The user changed their mind while we were connecting.
                rt.mountPoint = path
                _ = await performUnmount(id, force: false, reason: "Cancelled", isInternal: true)
                return
            }
            didMount(share, at: path, address: address, reconnected: reason == .reconnect || reason == .wake || reason == .network)
        } catch {
            handleMountError(error, share: share)
        }
    }

    private func finishCancelled(_ rt: ShareRuntime) {
        if !rt.state.isMounted { rt.state = .disconnected }
    }

    private func didMount(_ share: Share, at path: String, address: ServerAddress, reconnected: Bool) {
        let rt = runtime(for: share.id)
        rt.state = .mounted
        rt.mountPoint = path
        rt.connectedSince = Date()
        rt.attempt = 0
        rt.lastError = nil
        rt.staleSince = nil
        rt.wakeAttempted = false
        rt.nextRetryAt = nil
        log.add(.info, "\(reconnected ? "Reconnected" : "Mounted") at \(path) via \(address.display)", share: share)
        onEvent?(.mounted(share, path: path, reconnected: reconnected))
        if let hook = postMountHook {
            Task { await hook(share, path) }
        }
    }

    private func handleMountError(_ error: MountError, share: Share) {
        let rt = runtime(for: share.id)
        rt.lastError = error.message
        switch error.kind {
        case .alreadyMounted:
            if let entry = MountTable.find(share, knownMountPoint: rt.mountPoint, in: MountTable.smbMounts()) {
                adopt(entry, for: share, announce: true)
            } else {
                rt.state = .failed
                log.add(.error, error.message, share: share)
                scheduleRetry(share.id)
            }
        case .authentication, .passwordExpired:
            rt.state = .authFailed
            rt.attempt = 0
            log.add(.error, "Authentication failed: \(error.message)", share: share)
            onEvent?(.authFailed(share, message: error.message))
        case .hostUnreachable, .timedOut:
            rt.state = .hostUnreachable
            if rt.attempt == 0 { log.add(.warning, error.message, share: share) }
            scheduleRetry(share.id)
        case .cancelled:
            rt.state = .disconnected
        case .mountPointUnavailable, .invalidConfiguration:
            rt.state = .failed
            log.add(.error, error.message, share: share)
        case .shareNotFound, .other:
            rt.state = .failed
            log.add(.error, "\(error.message) [\(error.code)]", share: share)
            scheduleRetry(share.id)
        }
    }

    private func scheduleRetry(_ id: UUID) {
        let rt = runtime(for: id)
        guard rt.wantsMounted else { return }
        rt.attempt += 1
        let delay = Backoff(maximum: prefs.maxRetryDelay).delay(forAttempt: rt.attempt)
        rt.nextRetryAt = Date().addingTimeInterval(delay)
        rt.retryTask?.cancel()
        rt.retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.runtimes[id]?.retryTask = nil
            self.connect(id, reason: .retry)
        }
    }

    private func firstReachable(_ candidates: [ServerAddress], share: Share, quiet: Bool = false) async -> (ServerAddress, Duration)? {
        // Probe all candidates concurrently but honor the configured order: the first address
        // in the list that answers wins, even if a later one answered faster.
        let results = await withTaskGroup(of: (Int, Reachability.Result).self) { group in
            for (index, address) in candidates.enumerated() {
                group.addTask {
                    (index, await Reachability.probe(host: address.trimmedHost, port: address.effectivePort, timeout: .seconds(3)))
                }
            }
            var out = [Reachability.Result?](repeating: nil, count: candidates.count)
            for await (index, result) in group { out[index] = result }
            return out
        }
        for (index, result) in results.enumerated() {
            if case .reachable(let latency)? = result { return (candidates[index], latency) }
            if !quiet, let result {
                log.add(.debug, "\(candidates[index].display): \(String(describing: result))", share: share)
            }
        }
        return nil
    }

    /// Records a mount we didn't create (or found at launch).
    private func adopt(_ entry: MountTable.Entry, for share: Share, announce: Bool) {
        let rt = runtime(for: share.id)
        let wasMounted = rt.state == .mounted && rt.mountPoint == entry.mountPoint
        rt.state = .mounted
        rt.mountPoint = entry.mountPoint
        rt.activeAddress = entry.host
        rt.activeAddressKind = AddressClassifier.classify(entry.host)
        rt.wantsMounted = true
        rt.attempt = 0
        rt.lastError = nil
        if rt.connectedSince == nil { rt.connectedSince = Date() }
        if !wasMounted {
            log.add(.info, "Found existing mount at \(entry.mountPoint)", share: share)
            if announce { onEvent?(.mounted(share, path: entry.mountPoint, reconnected: false)) }
        }
    }

    private func adoptExistingMounts() {
        let entries = MountTable.smbMounts()
        for share in store.config.shares {
            if let entry = MountTable.find(share, in: entries) { adopt(entry, for: share, announce: false) }
        }
    }

    // MARK: - Unmounting

    private func performUnmount(_ id: UUID, force: Bool, reason: String, isInternal: Bool = false) async -> UnmountOutcome {
        let rt = runtime(for: id)
        let share = share(id)
        let path = rt.mountPoint ?? share.flatMap { MountTable.find($0, in: MountTable.smbMounts())?.mountPoint }
        guard let path else {
            if !rt.isBusy || rt.state.isProblem || !isInternal { rt.state = .disconnected }
            rt.mountPoint = nil
            return .notMounted
        }

        let previous = rt.state
        rt.state = .unmounting
        rt.expectingUnmount = true
        defer { rt.expectingUnmount = false }
        if let share { preUnmountHook?(share, path) }

        // A stale mount won't answer DiskArbitration's questions; go straight to the syscall.
        let useForce = force || previous == .stale
        do {
            if useForce {
                try await DiskWatcher.forceUnmount(path: path)
            } else {
                try await DiskWatcher.shared.unmount(path: path, force: false, timeout: .seconds(15))
            }
        } catch {
            if error.isBusy && !force {
                rt.state = previous
                if let share { log.add(.warning, "Could not unmount: \(error.message)", share: share) }
                return .busy(error.message)
            }
            // Escalate once.
            do {
                try await DiskWatcher.forceUnmount(path: path)
            } catch {
                rt.state = previous
                if let share { log.add(.error, "Force unmount failed: \(error.message)", share: share) }
                return .failed(error.message)
            }
        }

        rt.mountPoint = nil
        rt.connectedSince = nil
        rt.staleSince = nil
        if !isInternal || rt.state == .unmounting { rt.state = .disconnected }
        if let share {
            log.add(.info, "\(reason)\(useForce ? " (forced)" : "")", share: share)
            if !isInternal { onEvent?(.disconnected(share, reason: reason)) }
        }
        return .unmounted
    }

    // MARK: - Health checks

    private func startHealthChecks() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.prefs.probeInterval ?? 20
                try? await Task.sleep(for: .seconds(max(5, interval)))
                guard let self, !Task.isCancelled else { return }
                self.healthCheck()
            }
        }
    }

    /// Probes all mounted shares now (also used after wake and network changes).
    public func healthCheck() {
        guard !isSleeping else { return }
        let entries = MountTable.smbMounts()
        for share in store.config.shares {
            let rt = runtime(for: share.id)
            if rt.state.isMounted, rt.operation == nil {
                if let path = rt.mountPoint, !entries.contains(where: { $0.mountPoint == path }) {
                    // Gone without a DiskArbitration event (can happen after sleep).
                    mountVanished(share, path: path)
                } else {
                    probe(share)
                }
            } else if !rt.state.isMounted, rt.operation == nil, let entry = MountTable.find(share, in: entries) {
                adopt(entry, for: share, announce: false)
            }
        }
    }

    private func probe(_ share: Share) {
        let rt = runtime(for: share.id)
        guard let path = rt.mountPoint, !rt.probeInFlight else { return }
        rt.probeInFlight = true
        Task {
            let result = await FileSystemProbe.probe(mountPoint: path, timeout: .seconds(prefs.probeTimeout))
            rt.probeInFlight = false
            guard rt.mountPoint == path, rt.operation == nil else { return }
            switch result {
            case .alive(let latency):
                rt.recordLatency(latency)
                if rt.state == .stale {
                    rt.state = .mounted
                    rt.staleSince = nil
                    rt.lastError = nil
                    log.add(.info, "Responding again", share: share)
                }
            case .notMounted:
                mountVanished(share, path: path)
            case .timedOut, .error:
                let detail: String = if case .error(let code) = result { String(cString: strerror(code)) } else { "timed out" }
                if rt.state != .stale {
                    rt.state = .stale
                    rt.staleSince = Date()
                    rt.lastError = "The server stopped responding (\(detail))."
                    log.add(.warning, "Mount not responding (\(detail))", share: share)
                    if prefs.notifyOnStale { onEvent?(.stale(share)) }
                }
                if prefs.forceUnmountStale, let since = rt.staleSince,
                   Date().timeIntervalSince(since) >= prefs.staleGracePeriod {
                    recoverStale(share)
                } else if prefs.forceUnmountStale {
                    // Re-check soon so recovery happens close to the grace period.
                    Task {
                        try? await Task.sleep(for: .seconds(max(3, prefs.staleGracePeriod / 2)))
                        if rt.state == .stale { probe(share) }
                    }
                }
            }
        }
    }

    /// Force-unmounts a dead mount and brings it back as soon as the server is reachable.
    private func recoverStale(_ share: Share) {
        let rt = runtime(for: share.id)
        guard rt.operation == nil else { return }
        rt.operation = Task { [weak self] in
            guard let self else { return }
            log.add(.warning, "Force-unmounting dead mount", share: share)
            _ = await performUnmount(share.id, force: true, reason: "Removed dead mount", isInternal: true)
            rt.state = .reconnecting
            rt.operation = nil
            if rt.wantsMounted { connect(share.id, reason: .reconnect) } else { rt.state = .disconnected }
        }
    }

    private func mountVanished(_ share: Share, path: String) {
        let rt = runtime(for: share.id)
        guard rt.mountPoint == path, !rt.expectingUnmount else { return }
        rt.mountPoint = nil
        rt.connectedSince = nil
        rt.staleSince = nil
        let ejected = rt.ejectRequestedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        rt.ejectRequestedAt = nil
        if ejected {
            // Respect a deliberate eject: don't fight the user by remounting.
            rt.wantsMounted = false
            rt.overridesRule = false
            rt.retryTask?.cancel()
            rt.state = .disconnected
            log.add(.info, "Ejected outside Berth", share: share)
            onEvent?(.ejected(share))
        } else {
            log.add(.warning, "Mount disappeared unexpectedly", share: share)
            onEvent?(.disconnected(share, reason: "The connection was lost."))
            if rt.wantsMounted {
                rt.state = .reconnecting
                connect(share.id, reason: .reconnect)
            } else {
                rt.state = .disconnected
            }
        }
    }

    // MARK: - Disk events

    private func handleDiskEvent(_ event: DiskWatcher.Event) {
        switch event {
        case .unmountRequested(let path):
            if let rt = runtimes.values.first(where: { $0.mountPoint == path }), !rt.expectingUnmount {
                rt.ejectRequestedAt = Date()
            }
        case .disappeared(let path):
            if let rt = runtimes.values.first(where: { $0.mountPoint == path }), let share = share(rt.id) {
                mountVanished(share, path: path)
            }
        case .appeared:
            // Something mounted a network volume — maybe one of ours via Finder.
            let entries = MountTable.smbMounts()
            for share in store.config.shares {
                let rt = runtime(for: share.id)
                guard !rt.state.isMounted, rt.operation == nil else { continue }
                if let entry = MountTable.find(share, in: entries) { adopt(entry, for: share, announce: false) }
            }
        }
    }

    // MARK: - Network

    private func networkChanged(from old: NetworkSnapshot, to new: NetworkSnapshot) {
        log.add(.info, "Network changed: \(new.summary)")
        if old.tailscale.isUp != new.tailscale.isUp {
            log.add(.info, new.tailscale.isUp ? "Tailscale connected" : "Tailscale disconnected")
        }
        guard !isSleeping else { return }

        for share in store.config.shares {
            let rt = runtime(for: share.id)
            rt.attempt = 0
            rt.wakeAttempted = false
            let decision = RuleEvaluator.evaluate(share: share, network: new, homeNetworks: store.config.homeNetworks)

            if rt.state.isMounted {
                if case .blocked(let message) = decision, !rt.overridesRule {
                    // Left the allowed network: unmount cleanly before the mount goes stale.
                    Task {
                        _ = await performUnmount(share.id, force: true, reason: "Left allowed network", isInternal: true)
                        rt.state = .paused(.networkRule(message))
                    }
                } else if rt.activeAddressKind == .tailscale && !new.tailscale.isUp {
                    // The mount rode on the tunnel that just went away.
                    rt.state = .stale
                    rt.staleSince = Date().addingTimeInterval(-prefs.staleGracePeriod)
                    recoverStale(share)
                } else {
                    probe(share)
                }
                continue
            }

            if share.autoMount == .whenAvailable, prefs.autoMountEnabled, !rt.wantsMounted, case .allowed = decision {
                rt.wantsMounted = true
            }
            guard rt.wantsMounted else { continue }
            rt.retryTask?.cancel()
            rt.retryTask = nil
            connect(share.id, reason: .network)
        }
    }

    // MARK: - Sleep / wake

    private func systemWillSleep(completion: @escaping @MainActor () -> Void) {
        isSleeping = true
        log.add(.info, "System going to sleep")
        for rt in runtimes.values {
            rt.retryTask?.cancel()
            rt.retryTask = nil
        }
        guard prefs.unmountBeforeSleep else { completion(); return }
        let mounted = store.config.shares.filter { runtime(for: $0.id).state.isMounted }
        guard !mounted.isEmpty else { completion(); return }
        Task {
            let tasks = mounted.map { share in
                let rt = runtime(for: share.id)
                rt.remountAfterWake = rt.wantsMounted
                return Task {
                    let outcome = await self.performUnmount(share.id, force: false, reason: "Unmounted before sleep", isInternal: true)
                    if case .busy = outcome {
                        _ = await self.performUnmount(share.id, force: true, reason: "Unmounted before sleep", isInternal: true)
                    }
                    rt.state = .paused(.sleeping)
                }
            }
            for task in tasks { await task.value }
            completion()
        }
    }

    private func systemDidWake() {
        guard isSleeping else { return }
        isSleeping = false
        log.add(.info, "System woke up")
        network.refreshNow()
        Task {
            // Interfaces, DHCP, Wi-Fi association and VPN tunnels need a moment after wake.
            try? await Task.sleep(for: .seconds(4))
            for share in store.config.shares {
                let rt = runtime(for: share.id)
                rt.attempt = 0
                rt.wakeAttempted = false
                if rt.state == .paused(.sleeping) { rt.state = .disconnected }
                if rt.remountAfterWake {
                    rt.remountAfterWake = false
                    if prefs.remountAfterWake { rt.wantsMounted = true } else { rt.wantsMounted = false }
                }
                if rt.state.isMounted {
                    probe(share)
                } else if rt.wantsMounted {
                    connect(share.id, reason: .wake)
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Reachability of every address of a share (used by "Test Connection" and diagnostics).
    public func testAddresses(of share: Share) async -> [(ServerAddress, Reachability.Result)] {
        await withTaskGroup(of: (Int, Reachability.Result).self) { group in
            for (i, address) in share.addresses.enumerated() where !address.trimmedHost.isEmpty {
                group.addTask { (i, await Reachability.probe(host: address.trimmedHost, port: address.effectivePort, timeout: .seconds(4))) }
            }
            var results: [(Int, Reachability.Result)] = []
            for await r in group { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.map { (share.addresses[$0.0], $0.1) }
        }
    }

    /// Aggregate state for the menu bar icon.
    public var aggregate: AggregateState {
        let states = store.config.shares.map { runtime(for: $0.id).state }
        if states.contains(where: { $0 == .authFailed || $0 == .failed }) { return .problem }
        if states.contains(where: { $0.tone == .warning }) && states.contains(where: { _ in true }) {
            // Only flag warnings for shares the user wants mounted.
            let wanted = store.config.shares.filter { runtime(for: $0.id).wantsMounted }.map { runtime(for: $0.id).state }
            if wanted.contains(where: { $0.tone == .warning }) { return .problem }
        }
        if states.contains(where: \.isBusy) { return .busy }
        if states.contains(where: \.isMounted) { return .mounted }
        return .idle
    }

    public enum AggregateState: Sendable { case idle, mounted, busy, problem }

    public var mountedCount: Int { runtimes.values.filter { $0.state.isMounted }.count }
}
