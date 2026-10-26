import Foundation
import Network

/// Discovers SMB servers advertised over Bonjour (`_smb._tcp`).
@MainActor
@Observable
public final class BonjourBrowser {
    public struct Server: Identifiable, Hashable, Sendable {
        public var name: String
        /// The Bonjour host name, e.g. "nas.local".
        public var host: String
        public var model: String?
        public var id: String { name }
    }

    public private(set) var servers: [Server] = []
    public private(set) var isBrowsing = false
    public private(set) var error: String?

    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_smb._tcp", domain: "local."), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true; self?.error = nil
                case .failed(let err): self?.isBrowsing = false; self?.error = err.localizedDescription
                case .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Server] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var model: String?
                if case .bonjour(let txt) = result.metadata { model = txt["model"] }
                // Bonjour service names map to "<name>.local" host names for SMB servers.
                let host = name.replacingOccurrences(of: " ", with: "-") + ".local"
                return Server(name: name, host: host, model: model)
            }
            Task { @MainActor in
                self?.servers = found.uniqued().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    /// Resolves the real host name of a Bonjour service (handles names with spaces/punctuation).
    public static func resolveHost(serviceName: String) async -> String? {
        let endpoint = NWEndpoint.service(name: serviceName, type: "_smb._tcp", domain: "local.", interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let box = OnceBox<String?>()
        return await withCheckedContinuation { continuation in
            box.setHandler { value in
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        switch host {
                        case .name(let name, _): box.fire(name)
                        case .ipv4(let addr): box.fire("\(addr)".components(separatedBy: "%").first)
                        case .ipv6(let addr): box.fire("\(addr)".components(separatedBy: "%").first)
                        @unknown default: box.fire(nil)
                        }
                    } else {
                        box.fire(nil)
                    }
                case .failed, .cancelled: box.fire(nil)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { box.fire(nil) }
        }
    }
}
