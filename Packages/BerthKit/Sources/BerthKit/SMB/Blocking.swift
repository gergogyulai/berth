import Foundation
import Synchronization

/// Runs potentially-hanging syscalls (stat on a dead SMB mount, unmount…) on a dedicated thread.
///
/// A hung syscall cannot be cancelled, so it must never run on the cooperative thread pool or
/// the main thread. Each call gets its own thread; if it times out the thread is abandoned and
/// finishes (or not) on its own. Callers must make sure they do not pile up probes against the
/// same mount — see `ShareCoordinator`'s in-flight bookkeeping.
public enum Blocking {
    public static func run<T: Sendable>(timeout: Duration, name: String = "app.berth.blocking",
                                        _ work: @escaping @Sendable () -> T) async -> T? {
        let box = OnceBox<T?>()
        return await withCheckedContinuation { continuation in
            box.setHandler { continuation.resume(returning: $0) }
            let thread = Thread { box.fire(work()) }
            thread.name = name
            thread.qualityOfService = .utility
            thread.stackSize = 256 * 1024
            thread.start()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval) {
                box.fire(nil)
            }
        }
    }
}

/// Liveness probe for a mounted file system.
public enum FileSystemProbe {
    public enum Result: Sendable, Equatable {
        case alive(latency: Duration)
        case error(Int32)
        case timedOut
        case notMounted
    }

    /// Looks up a random, non-existent name in the mount's root. That forces a round trip to the
    /// server (it can't be answered from the attribute or negative cache) while being harmless.
    /// Mount points with a probe thread that has not returned yet. A probe against a dead server
    /// can block in the kernel for minutes; never start a second one against the same mount.
    private static let outstanding = Mutex<Set<String>>([])

    public static func hasOutstandingProbe(_ mountPoint: String) -> Bool {
        outstanding.withLock { $0.contains(mountPoint) }
    }

    public static func probe(mountPoint: String, timeout: Duration) async -> Result {
        let inserted = outstanding.withLock { $0.insert(mountPoint).inserted }
        guard inserted else { return .timedOut }
        let clock = ContinuousClock()
        let start = clock.now
        let probeName = "\(mountPoint)/.berth-probe-\(UInt32.random(in: 0...UInt32.max))"
        let result = await Blocking.run(timeout: timeout, name: "app.berth.probe") { () -> Int32 in
            defer { _ = outstanding.withLock { $0.remove(mountPoint) } }
            var fs = statfs()
            guard statfs(mountPoint, &fs) == 0 else { return errno }
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard type == "smbfs" else { return -1 }
            if access(probeName, F_OK) == 0 { return 0 }
            return errno == ENOENT ? 0 : errno
        }
        switch result {
        case nil: return .timedOut
        case let code? where code == -1: return .notMounted
        case let code? where code == 0: return .alive(latency: clock.now - start)
        case let code?: return code == ENOENT || code == ENOTDIR ? .notMounted : .error(code)
        }
    }
}
