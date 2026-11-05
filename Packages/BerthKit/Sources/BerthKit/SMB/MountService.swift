import Foundation

/// The macOS helper that performs NetFS mounts. launchd starts a new one on the next request, and
/// mounts that already exist live in the kernel, so restarting it doesn't affect them.
///
/// It's a private part of macOS: if the name ever changes, `restart()` finds nothing to kill and the
/// mount simply fails with the "stalled" error.
public enum MountService {
    private static let processName = "NetAuthSysAgent"

    /// Kills this user's helper. SIGKILL because a stuck helper has no useful shutdown to run.
    public static func restart() async -> Bool {
        await Blocking.run(timeout: .seconds(5), name: "app.berth.mountservice") { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["-KILL", processName]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        } ?? false
    }
}

/// Limits helper restarts, so a server that never answers can't turn into a restart loop.
struct RestartBudget {
    let limit: Int
    let window: TimeInterval
    private var history: [Date] = []

    init(limit: Int = 3, window: TimeInterval = 30 * 60) {
        self.limit = limit
        self.window = window
    }

    /// Spends one restart if any are left in the current window.
    mutating func consume(now: Date = Date()) -> Bool {
        history.removeAll { now.timeIntervalSince($0) >= window }
        guard history.count < limit else { return false }
        history.append(now)
        return true
    }
}
