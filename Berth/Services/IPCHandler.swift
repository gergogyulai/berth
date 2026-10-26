import Foundation
import BerthKit

/// Serves `berth` CLI requests against the live coordinator.
@MainActor
enum IPCHandler {
    static func handle(_ request: IPC.Request) async -> IPC.Response {
        let model = AppModel.shared
        let config = model.config

        func resolve() -> Share? {
            guard let target = request.target else { return nil }
            return config.resolveShare(target)
        }

        switch request.command {
        case .ping:
            return IPC.Response(ok: true, message: "pong", version: Bundle.main.shortVersion)

        case .list:
            return IPC.Response(ok: true, shares: config.shares.map(info))

        case .status:
            if request.target != nil {
                guard let share = resolve() else { return .failure("No share named “\(request.target!)”.") }
                return IPC.Response(ok: true, shares: [info(share)])
            }
            return IPC.Response(ok: true, shares: config.shares.map(info))

        case .groups:
            return IPC.Response(ok: true, groups: config.groups.map(\.name))

        case .mount:
            guard let share = resolve() else { return .failure("No share named “\(request.target ?? "")”.") }
            model.coordinator.mount(share.id)
            guard request.wait else { return IPC.Response(ok: true, message: "Mounting \(share.name)…") }
            return await waitForMount(share)

        case .reconnect:
            guard let share = resolve() else { return .failure("No share named “\(request.target ?? "")”.") }
            model.coordinator.reconnect(share.id)
            guard request.wait else { return IPC.Response(ok: true, message: "Reconnecting \(share.name)…") }
            try? await Task.sleep(for: .milliseconds(300))
            return await waitForMount(share)

        case .unmount:
            guard let share = resolve() else { return .failure("No share named “\(request.target ?? "")”.") }
            let outcome = await model.coordinator.unmount(share.id, force: request.force)
            return response(for: outcome, share: share)

        case .mountAll:
            let (groupID, only) = groupFilter(request.group)
            if request.group != nil && !only { return .failure("No group named “\(request.group!)”.") }
            model.coordinator.mountAll(groupID: groupID, onlyGroup: only)
            let targets = config.shares.filter { !only || $0.groupID == groupID }
            guard request.wait else { return IPC.Response(ok: true, message: "Mounting \(targets.count) shares…") }
            var lines: [String] = []
            var ok = true
            for share in targets {
                let r = await waitForMount(share)
                ok = ok && r.ok
                lines.append(r.message ?? share.name)
            }
            return IPC.Response(ok: ok, message: lines.joined(separator: "\n"), shares: targets.map(info))

        case .unmountAll:
            let (groupID, only) = groupFilter(request.group)
            if request.group != nil && !only { return .failure("No group named “\(request.group!)”.") }
            let results = await model.coordinator.unmountAll(groupID: groupID, onlyGroup: only, force: request.force)
            var lines: [String] = []
            var ok = true
            for share in config.shares where results[share.id] != nil {
                let r = response(for: results[share.id]!, share: share)
                if results[share.id] != .notMounted { lines.append(r.message ?? "") }
                ok = ok && r.ok
            }
            return IPC.Response(ok: ok, message: lines.isEmpty ? "Nothing was mounted." : lines.joined(separator: "\n"))
        }
    }

    private static func groupFilter(_ name: String?) -> (UUID?, Bool) {
        guard let name else { return (nil, false) }
        guard let group = AppModel.shared.config.resolveGroup(name) else { return (nil, false) }
        return (group.id, true)
    }

    private static func response(for outcome: UnmountOutcome, share: Share) -> IPC.Response {
        switch outcome {
        case .unmounted: IPC.Response(ok: true, message: "Unmounted \(share.name).")
        case .notMounted: IPC.Response(ok: true, message: "\(share.name) was not mounted.")
        case .busy(let msg): IPC.Response(ok: false, message: "\(share.name) is in use (\(msg)). Use --force to unmount anyway.")
        case .failed(let msg): IPC.Response(ok: false, message: "Could not unmount \(share.name): \(msg)")
        }
    }

    /// Waits until the share settles in a terminal state.
    private static func waitForMount(_ share: Share, timeout: Duration = .seconds(120)) async -> IPC.Response {
        let rt = AppModel.shared.runtime(share.id)
        let deadline = ContinuousClock.now + timeout
        // Let the coordinator pick the request up first.
        try? await Task.sleep(for: .milliseconds(150))
        while ContinuousClock.now < deadline {
            switch rt.state {
            case .mounted:
                return IPC.Response(ok: true, message: "Mounted \(share.name) at \(rt.mountPoint ?? "?")", shares: [info(share)])
            case .authFailed, .failed, .tailscaleDown, .paused:
                return IPC.Response(ok: false, message: "\(share.name): \(rt.lastError ?? rt.state.title)", shares: [info(share)])
            case .hostUnreachable where rt.retryTaskPending:
                return IPC.Response(ok: false, message: "\(share.name): \(rt.lastError ?? rt.state.title) Berth will keep retrying.", shares: [info(share)])
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return IPC.Response(ok: false, message: "\(share.name): still \(rt.state.title.lowercased())", shares: [info(share)])
    }

    static func info(_ share: Share) -> IPC.ShareInfo {
        let model = AppModel.shared
        let rt = model.runtime(share.id)
        let url = SMBURL.make(address: share.addresses.first ?? ServerAddress(), share: share.shareName, auth: share.auth,
                              username: share.username, domain: share.domain)?.absoluteString ?? share.locationSummary
        return IPC.ShareInfo(
            id: share.id, name: share.name, slug: share.slug, group: model.group(for: share)?.name, url: url,
            state: rt.state.code, stateTitle: rt.state.title, mountPoint: rt.mountPoint, address: rt.activeAddress,
            latencyMs: rt.lastProbeLatency?.inMilliseconds, error: rt.lastError
        )
    }
}

extension ShareRuntime {
    /// Whether a retry is scheduled (the coordinator will keep trying on its own).
    var retryTaskPending: Bool { nextRetryAt != nil }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "1" }
}
