import Foundation
import DiskArbitration
import os

/// Owns a DiskArbitration session and reports network volume events.
///
/// - `appeared`: something mounted a network volume (Berth, Finder, `mount_smbfs`…).
/// - `unmountRequested`: somebody asked DiskArbitration to unmount (a Finder eject, `diskutil`).
///   Berth uses this to tell a deliberate eject apart from a connection that died.
/// - `disappeared`: a network volume is gone, for whatever reason.
public final class DiskWatcher: @unchecked Sendable {
    public enum Event: Sendable {
        case appeared(path: String)
        case unmountRequested(path: String)
        case disappeared(path: String)
    }

    public static let shared = DiskWatcher()

    private let queue = DispatchQueue(label: "app.berth.diskarbitration")
    private let session: DASession?
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (Event) -> Void] = [:]
    private let log = Logger(subsystem: "app.berth", category: "diskarbitration")

    private init() {
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        DASessionSetDispatchQueue(session, queue)

        let match = [kDADiskDescriptionVolumeNetworkKey as String: true] as CFDictionary
        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, match, { disk, ctx in
            guard let ctx, let path = DiskWatcher.volumePath(disk) else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().emit(.appeared(path: path))
        }, context)

        DARegisterDiskDisappearedCallback(session, match, { disk, ctx in
            guard let ctx, let path = DiskWatcher.volumePath(disk) else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().emit(.disappeared(path: path))
        }, context)

        DARegisterDiskUnmountApprovalCallback(session, match, { disk, ctx in
            if let ctx, let path = DiskWatcher.volumePath(disk) {
                Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().emit(.unmountRequested(path: path))
            }
            return nil // never dissent
        }, context)
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (Event) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.withLock { _ = handlers.removeValue(forKey: id) }
    }

    private func emit(_ event: Event) {
        let current = lock.withLock { Array(handlers.values) }
        for handler in current { handler(event) }
    }

    static func volumePath(_ disk: DADisk) -> String? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL else { return nil }
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: Unmounting

    public struct UnmountError: LocalizedError, Sendable {
        public var message: String
        public var isBusy: Bool
        public var errorDescription: String? { message }
    }

    /// Asks DiskArbitration to unmount the volume. This lets other apps object ("in use by…") and
    /// keeps Finder in the loop.
    public func unmount(path: String, force: Bool = false, timeout: Duration = .seconds(20)) async throws(UnmountError) {
        guard let session else { throw UnmountError(message: "DiskArbitration is unavailable.", isBusy: false) }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url) else {
            // Not known to DA (already gone, or never registered) — fall back to the syscall.
            try await Self.forceUnmount(path: path, timeout: timeout)
            return
        }
        let box = OnceBox<UnmountError?>()
        final class Context { let box: OnceBox<UnmountError?>; init(_ b: OnceBox<UnmountError?>) { box = b } }
        let ctx = Unmanaged.passRetained(Context(box))

        let error: UnmountError? = await withCheckedContinuation { continuation in
            box.setHandler { continuation.resume(returning: $0) }
            let options = DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault)
            DADiskUnmount(disk, options, { _, dissenter, raw in
                guard let raw else { return }
                let context = Unmanaged<Context>.fromOpaque(raw).takeRetainedValue()
                if let dissenter {
                    let status = DADissenterGetStatus(dissenter)
                    let text = DADissenterGetStatusString(dissenter) as String?
                    let busy = status == kDAReturnBusy || status == kDAReturnExclusiveAccess
                    context.box.fire(UnmountError(
                        message: text ?? (busy ? "The volume is in use." : "Unmount failed (\(String(status, radix: 16))."),
                        isBusy: busy))
                } else {
                    context.box.fire(nil)
                }
            }, ctx.toOpaque())
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                box.fire(UnmountError(message: "Unmount timed out.", isBusy: false))
            }
        }
        if let error { throw error }
    }

    /// `unmount(2)` with MNT_FORCE: works on dead mounts where DiskArbitration would hang or dissent.
    public static func forceUnmount(path: String, timeout: Duration = .seconds(10)) async throws(UnmountError) {
        let code = await Blocking.run(timeout: timeout, name: "app.berth.unmount") { () -> Int32 in
            Darwin.unmount(path, MNT_FORCE) == 0 ? 0 : errno
        }
        switch code {
        case 0?, EINVAL?, ENOENT?: return // EINVAL: not a mount point any more
        case nil: throw UnmountError(message: "Force unmount timed out.", isBusy: false)
        case let c?: throw UnmountError(message: String(cString: strerror(c)), isBusy: c == EBUSY)
        }
    }
}
