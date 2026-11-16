import AppKit
import BerthKit

/// Unmounting and deleting on the user's behalf.
///
/// The coordinator reports what happened; these wrappers turn a refusal into the conversation Finder
/// has about a disk in use, instead of a click that silently does nothing. Automation (the CLI,
/// AppleScript, Shortcuts, `berth://`) keeps calling the coordinator directly: it gets the outcome
/// back and must never be stopped by an alert.
extension AppModel {
    /// Mounts, unmounts, or stops trying — whichever the share's state calls for.
    func toggle(_ id: UUID) {
        let rt = runtime(id)
        if rt.state.isMounted || rt.isTrying { unmount([id]) } else { coordinator.mount(id) }
    }

    func unmount(_ ids: [UUID], force: Bool = false) {
        Task { await unmountInteractively(ids, force: force, purpose: .unmount) }
    }

    func unmountAll(groupID: UUID? = nil, onlyGroup: Bool = false) {
        unmount(config.shares.filter { !onlyGroup || $0.groupID == groupID }.map(\.id))
    }

    /// Forcing a mount that still works can lose writes in progress, so that needs a yes first.
    /// A mount that's already dead has nothing left to lose.
    func forceUnmount(_ ids: [UUID]) {
        let healthy = ids.compactMap { config.share(id: $0) }.filter { runtime($0.id).state == .mounted }
        Task {
            if !healthy.isEmpty, await !ShareAlerts.confirmForce(healthy, purpose: .forceRequested) { return }
            await unmountInteractively(ids, force: true, purpose: .unmount)
        }
    }

    /// Deletes shares, unmounting them first. One that's in use is kept until the user agrees to
    /// force it.
    func delete(_ shares: [Share]) {
        Task {
            var busy: [Share] = []
            var failures: [ShareAlerts.Failure] = []
            for share in shares {
                switch await coordinator.remove(share.id, unmountFirst: true) {
                case .busy: busy.append(share)
                case .failed(let message): failures.append(.init(share: share, message: message))
                case .unmounted, .notMounted: break
                }
            }
            if !failures.isEmpty { await ShareAlerts.report(failures, purpose: .delete) }
            guard !busy.isEmpty, await ShareAlerts.confirmForce(busy, purpose: .delete) else { return }
            failures = []
            for share in busy {
                if case .failed(let message) = await coordinator.remove(share.id, unmountFirst: true, force: true) {
                    failures.append(.init(share: share, message: message))
                }
            }
            if !failures.isEmpty { await ShareAlerts.report(failures, purpose: .delete) }
        }
    }

    /// Returns true when none of the shares is mounted any more.
    @discardableResult
    func unmountInteractively(_ ids: [UUID], force: Bool, purpose: ShareAlerts.Purpose) async -> Bool {
        // All at once (each is mostly waiting on DiskArbitration), then collect.
        let tasks = ids.map { id in (id, Task { await self.coordinator.unmount(id, force: force) }) }
        var busy: [Share] = []
        var failures: [ShareAlerts.Failure] = []
        for (id, task) in tasks {
            let outcome = await task.value
            guard let share = config.share(id: id) else { continue }
            switch outcome {
            case .busy: busy.append(share)
            case .failed(let message): failures.append(.init(share: share, message: message))
            case .unmounted, .notMounted: break
            }
        }
        if !failures.isEmpty { await ShareAlerts.report(failures, purpose: purpose) }
        guard !busy.isEmpty else { return failures.isEmpty }
        guard await ShareAlerts.confirmForce(busy, purpose: purpose) else { return false }
        return await unmountInteractively(busy.map(\.id), force: true, purpose: purpose) && failures.isEmpty
    }
}

/// The alerts for unmounts that didn't go through.
@MainActor
enum ShareAlerts {
    enum Purpose {
        case unmount
        case delete
        /// The user picked Force Unmount for a mount that's working.
        case forceRequested
    }

    struct Failure {
        var share: Share
        var message: String
    }

    /// Asks before forcing. Nothing is the default button: Return must not be able to lose data.
    static func confirmForce(_ shares: [Share], purpose: Purpose) async -> Bool {
        guard !shares.isEmpty else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let one = shares.count == 1 ? shares[0].name : nil
        switch purpose {
        case .unmount:
            alert.messageText = one.map { String(localized: "“\($0)” couldn’t be unmounted because it’s in use.") }
                ?? String(localized: "\(shares.count) shares couldn’t be unmounted because they’re in use.")
        case .delete:
            alert.messageText = one.map { String(localized: "“\($0)” wasn’t deleted because it’s in use.") }
                ?? String(localized: "\(shares.count) shares weren’t deleted because they’re in use.")
        case .forceRequested:
            alert.messageText = one.map { String(localized: "Force “\($0)” to unmount?") }
                ?? String(localized: "Force \(shares.count) shares to unmount?")
        }
        var info: [String] = []
        if one == nil { info.append(shares.map(\.name).formatted(.list(type: .and))) }
        info.append(purpose == .forceRequested
            ? String(localized: "Files that are open on the share may lose unsaved changes.")
            : String(localized: "Close the files and windows that use it and try again. Forcing it may lose unsaved changes in open files."))
        alert.informativeText = info.joined(separator: "\n\n")

        let force = alert.addButton(withTitle: purpose == .delete
            ? String(localized: "Force Unmount & Delete") : String(localized: "Force Unmount"))
        force.hasDestructiveAction = true
        force.keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await present(alert) == .alertFirstButtonReturn
    }

    static func report(_ failures: [Failure], purpose: Purpose) async {
        guard let first = failures.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if failures.count == 1 {
            alert.messageText = purpose == .delete
                ? String(localized: "“\(first.share.name)” wasn’t deleted because it couldn’t be unmounted.")
                : String(localized: "“\(first.share.name)” couldn’t be unmounted.")
            alert.informativeText = first.message
        } else {
            alert.messageText = purpose == .delete
                ? String(localized: "\(failures.count) shares weren’t deleted because they couldn’t be unmounted.")
                : String(localized: "\(failures.count) shares couldn’t be unmounted.")
            alert.informativeText = failures.map { "\($0.share.name): \($0.message)" }.joined(separator: "\n")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await present(alert)
    }

    /// A sheet on the main window when the user is looking at it, otherwise an alert of its own
    /// (the request may have come from the menu bar, the Dock or a hot key).
    static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = frontMainWindow {
            return await alert.beginSheetModal(for: window)
        }
        let box = AlertBox(alert: alert)
        return await withCheckedContinuation { continuation in
            // Via the run loop, not from this task: a modal session started inside a main-queue job
            // keeps the main queue from draining, which would freeze every main-actor task (the
            // whole engine) for as long as the alert is up.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    NSApp.activate()
                    continuation.resume(returning: box.alert.runModal())
                }
            }
        }
    }

    private static var frontMainWindow: NSWindow? {
        guard NSApp.isActive,
              let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.main }),
              window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else { return nil }
        return window
    }

    private struct AlertBox: @unchecked Sendable { let alert: NSAlert }
}
