import Foundation

/// Lets one mount through at a time, in request order.
///
/// Every NetFS mount goes through a single per-user macOS helper (NetAuthSysAgent), and simultaneous
/// mounts have been seen to hang it for good in its account lookup, which then blocks all later
/// mounts. So Berth never has two requests in flight, even for different servers.
@MainActor
final class MountGate {
    private var isHeld = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Waits for a turn. Returns false if the task was cancelled while waiting; call `release()`
    /// only after this returns true.
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isHeld else {
            isHeld = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
