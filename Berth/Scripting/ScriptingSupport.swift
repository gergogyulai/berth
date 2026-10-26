import AppKit
import BerthKit

/// AppleScript view of a share (`tell application "Berth" to get state of share "Media"`).
@objc(ScriptableShare)
nonisolated final class ScriptableShare: NSObject, @unchecked Sendable {
    private let shareID: UUID

    init(_ share: Share) {
        self.shareID = share.id
    }

    /// AppleScript always calls in on the main thread.
    private func read<T: Sendable>(_ body: @MainActor (Share?, ShareRuntime) -> T) -> T {
        let id = shareID
        return MainActor.assumeIsolated {
            body(AppModel.shared.config.share(id: id), AppModel.shared.runtime(id))
        }
    }

    @objc var uniqueID: String { shareID.uuidString }
    @objc var name: String { read { s, _ in s?.name ?? "" } }
    @objc var slug: String { read { s, _ in s?.slug ?? "" } }
    @objc var state: String { read { _, rt in rt.state.code } }
    @objc var mounted: Bool { read { _, rt in rt.state.isMounted } }
    @objc var mountPoint: String { read { _, rt in rt.mountPoint ?? "" } }
    @objc var server: String { read { s, _ in s?.primaryHost ?? "" } }
    @objc var groupName: String { read { s, _ in s.flatMap { AppModel.shared.group(for: $0)?.name } ?? "" } }
    @objc var lastError: String { read { _, rt in rt.lastError ?? "" } }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let appDescription = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: appDescription, containerSpecifier: nil,
                                   key: "scriptableShares", uniqueID: uniqueID)
    }
}

/// Shared helpers for Berth's script commands.
nonisolated class BerthScriptCommand: NSScriptCommand, @unchecked Sendable {
    /// Resolves the direct parameter (a share specifier or a name) to share ids.
    @MainActor
    func targetShareIDs() -> [UUID]? {
        let config = AppModel.shared.config
        // With an `any` direct parameter, plain text arrives as an unconverted descriptor.
        let text = (directParameter as? String) ?? (directParameter as? NSAppleEventDescriptor)?.stringValue
        if let name = text, (directParameter as? NSAppleEventDescriptor)?.descriptorType != typeObjectSpecifier {
            return config.resolveShare(name).map { [$0.id] }
        }
        let specifier = (directParameter as? NSScriptObjectSpecifier)
            ?? (directParameter as? NSAppleEventDescriptor).flatMap(NSScriptObjectSpecifier.init(descriptor:))
        if let specifier {
            let resolved = specifier.objectsByEvaluatingSpecifier
            if let one = resolved as? ScriptableShare { return [UUID(uuidString: one.uniqueID)!] }
            if let many = resolved as? [ScriptableShare] { return many.compactMap { UUID(uuidString: $0.uniqueID) } }
        }
        if let shares = evaluatedReceivers as? [ScriptableShare] { return shares.compactMap { UUID(uuidString: $0.uniqueID) } }
        if let share = evaluatedReceivers as? ScriptableShare { return UUID(uuidString: share.uniqueID).map { [$0] } }
        return nil
    }

    func fail(_ message: String) {
        scriptErrorNumber = errAEEventFailed
        scriptErrorString = message
    }

    /// Hand the result back once async work finishes.
    func resume(_ result: Bool?) {
        resumeExecution(withResult: result.map { NSNumber(value: $0) })
    }

    @MainActor
    func groupFilter() -> (UUID?, Bool)? {
        guard let name = evaluatedArguments?["group"] as? String else { return (nil, false) }
        guard let group = AppModel.shared.config.resolveGroup(name) else { return nil }
        return (group.id, true)
    }
}

@objc(BerthMountCommand)
nonisolated final class BerthMountCommand: BerthScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        let command = UncheckedBox(self)
        MainActor.assumeIsolated { command.value.run() }
        return nil
    }

    @MainActor private func run() {
        guard let ids = targetShareIDs(), !ids.isEmpty else { fail("No such share."); return }
        let model = AppModel.shared
        ids.forEach { model.coordinator.mount($0) }
        // Hold the reply until the mount settles, so scripts can rely on the result.
        suspendExecution()
        Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(90)
            while ContinuousClock.now < deadline {
                let states = ids.map { model.runtime($0).state }
                if states.allSatisfy({ $0 == .mounted }) { break }
                if states.contains(where: { $0 == .authFailed || $0 == .failed || $0 == .tailscaleDown || $0 == .hostUnreachable }) { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            resume(ids.allSatisfy { model.runtime($0).state == .mounted })
        }
    }
}

@objc(BerthUnmountCommand)
nonisolated final class BerthUnmountCommand: BerthScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        let command = UncheckedBox(self)
        MainActor.assumeIsolated { command.value.run() }
        return nil
    }

    @MainActor private func run() {
        guard let ids = targetShareIDs(), !ids.isEmpty else { fail("No such share."); return }
        let force = evaluatedArguments?["force"] as? Bool ?? false
        suspendExecution()
        Task { @MainActor in
            var ok = true
            for id in ids {
                let outcome = await AppModel.shared.coordinator.unmount(id, force: force)
                if case .busy = outcome { ok = false }
                if case .failed = outcome { ok = false }
            }
            resume(ok)
        }
    }
}

@objc(BerthReconnectCommand)
nonisolated final class BerthReconnectCommand: BerthScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        let command = UncheckedBox(self)
        MainActor.assumeIsolated { command.value.run() }
        return nil
    }

    @MainActor private func run() {
        guard let ids = targetShareIDs(), !ids.isEmpty else { fail("No such share."); return }
        ids.forEach { AppModel.shared.coordinator.reconnect($0) }
    }
}

@objc(BerthMountAllCommand)
nonisolated final class BerthMountAllCommand: BerthScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        let command = UncheckedBox(self)
        MainActor.assumeIsolated { command.value.run() }
        return nil
    }

    @MainActor private func run() {
        guard let (groupID, only) = groupFilter() else { fail("No such group."); return }
        AppModel.shared.coordinator.mountAll(groupID: groupID, onlyGroup: only)
    }
}

@objc(BerthUnmountAllCommand)
nonisolated final class BerthUnmountAllCommand: BerthScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        let command = UncheckedBox(self)
        MainActor.assumeIsolated { command.value.run() }
        return nil
    }

    @MainActor private func run() {
        guard let (groupID, only) = groupFilter() else { fail("No such group."); return }
        let force = evaluatedArguments?["force"] as? Bool ?? false
        suspendExecution()
        Task { @MainActor in
            await AppModel.shared.coordinator.unmountAll(groupID: groupID, onlyGroup: only, force: force)
            resume(nil)
        }
    }
}

/// NSScriptCommand isn't Sendable, but AppleScript always delivers commands on the main thread.
nonisolated private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
