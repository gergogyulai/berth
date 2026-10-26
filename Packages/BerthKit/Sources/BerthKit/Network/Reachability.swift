import Foundation
import Network

/// Cheap "is the SMB port answering?" check, used before mounting and to tell a dead server apart
/// from a dead mount.
public enum Reachability {
    public enum Result: Sendable, Equatable {
        case reachable(latency: Duration)
        case refused
        case unreachable(String)
        case timedOut

        public var isReachable: Bool {
            if case .reachable = self { return true }
            return false
        }

        public var latency: Duration? {
            if case .reachable(let l) = self { return l }
            return nil
        }
    }

    public static func probe(host: String, port: Int = 445, timeout: Duration = .seconds(3)) async -> Result {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .unreachable("Invalid port") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(max(1, timeout.components.seconds))
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = [.loopback]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let clock = ContinuousClock()
        let start = clock.now
        let box = OnceBox<Result>()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                box.setHandler { result in
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.fire(.reachable(latency: clock.now - start))
                    case .waiting(let error), .failed(let error):
                        if case .posix(let code) = error, code == .ECONNREFUSED {
                            box.fire(.refused)
                        } else if case .waiting = state, case .posix(let code) = error, code == .ENETDOWN || code == .ENETUNREACH {
                            box.fire(.unreachable(error.localizedDescription))
                        } else if case .failed = state {
                            box.fire(.unreachable(error.localizedDescription))
                        } else if case .dns = error {
                            box.fire(.unreachable("Name could not be resolved"))
                        }
                        // Other "waiting" states may still resolve; let the timeout decide.
                    case .cancelled:
                        box.fire(.timedOut)
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                    box.fire(.timedOut)
                }
            }
        } onCancel: {
            box.fire(.timedOut)
        }
    }
}

/// A thread-safe "resume exactly once" helper for bridging callback APIs.
final class OnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?
    private var pending: Value?
    private var fired = false

    func setHandler(_ handler: @escaping (Value) -> Void) {
        lock.lock()
        if fired, let pending {
            lock.unlock()
            handler(pending)
            return
        }
        self.handler = handler
        lock.unlock()
    }

    func fire(_ value: Value) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        if let handler {
            self.handler = nil
            lock.unlock()
            handler(value)
        } else {
            pending = value
            lock.unlock()
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    public var inMilliseconds: Double { timeInterval * 1000 }
}
