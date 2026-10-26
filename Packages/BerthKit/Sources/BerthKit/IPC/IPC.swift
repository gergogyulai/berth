import Foundation
import os

/// Line-delimited JSON over a per-user Unix domain socket. Used by the `berth` CLI.
public enum IPC {
    public static var socketURL: URL {
        ConfigStore.supportDirectory.appending(path: "berth.sock")
    }

    public enum Command: String, Codable, Sendable, CaseIterable {
        case ping, list, status, mount, unmount, mountAll, unmountAll, reconnect, groups
    }

    public struct Request: Codable, Sendable {
        public var command: Command
        public var target: String?
        public var group: String?
        public var force: Bool
        public var wait: Bool

        public init(command: Command, target: String? = nil, group: String? = nil, force: Bool = false, wait: Bool = true) {
            self.command = command
            self.target = target
            self.group = group
            self.force = force
            self.wait = wait
        }
    }

    public struct ShareInfo: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var slug: String
        public var group: String?
        public var url: String
        public var state: String
        public var stateTitle: String
        public var mountPoint: String?
        public var address: String?
        public var latencyMs: Double?
        public var error: String?

        public init(id: UUID, name: String, slug: String, group: String?, url: String, state: String, stateTitle: String,
                    mountPoint: String?, address: String?, latencyMs: Double?, error: String?) {
            self.id = id
            self.name = name
            self.slug = slug
            self.group = group
            self.url = url
            self.state = state
            self.stateTitle = stateTitle
            self.mountPoint = mountPoint
            self.address = address
            self.latencyMs = latencyMs
            self.error = error
        }
    }

    public struct Response: Codable, Sendable {
        public var ok: Bool
        public var message: String?
        public var shares: [ShareInfo]?
        public var groups: [String]?
        public var version: String?

        public init(ok: Bool, message: String? = nil, shares: [ShareInfo]? = nil, groups: [String]? = nil, version: String? = nil) {
            self.ok = ok
            self.message = message
            self.shares = shares
            self.groups = groups
            self.version = version
        }

        public static func failure(_ message: String) -> Response { Response(ok: false, message: message) }
    }
}

// MARK: - Server

public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPC.Request) async -> IPC.Response

    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "app.berth.ipc")
    private let log = Logger(subsystem: "app.berth", category: "ipc")

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start() throws {
        let path = IPC.socketURL.path
        try FileManager.default.createDirectory(at: IPC.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = try Self.address(for: path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // Only this user may talk to us.
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(IPC.socketURL.path)
    }

    static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private func acceptConnection() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        // Accepted sockets inherit O_NONBLOCK from the listener on Darwin; we want blocking I/O
        // (bounded by SO_RCVTIMEO) on the per-connection thread.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        // Defense in depth on top of the 0600 socket: check the peer's uid.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let handler = self.handler
        Thread.detachNewThread {
            guard let line = IPCLineIO.readLine(fd: client),
                  let request = try? JSONDecoder().decode(IPC.Request.self, from: line) else {
                IPCLineIO.write(IPC.Response.failure("Malformed request"), to: client)
                close(client)
                return
            }
            Task {
                let response = await handler(request)
                IPCLineIO.write(response, to: client)
                close(client)
            }
        }
    }
}

// MARK: - Client

public enum IPCClient {
    public enum ClientError: LocalizedError {
        case notRunning
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: "Berth is not running."
            case .io(let message): message
            }
        }
    }

    public static func send(_ request: IPC.Request, timeout: TimeInterval = 120) throws -> IPC.Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.io("socket() failed") }
        defer { close(fd) }
        var addr = try IPCServer.address(for: IPC.socketURL.path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ClientError.notRunning }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        IPCLineIO.write(request, to: fd)
        guard let line = IPCLineIO.readLine(fd: fd) else { throw ClientError.io("No response from Berth.") }
        do {
            return try JSONDecoder().decode(IPC.Response.self, from: line)
        } catch {
            throw ClientError.io("Unreadable response from Berth.")
        }
    }
}

enum IPCLineIO {
    static func readLine(fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            if let nl = buffer[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<nl])
                return data
            }
            data.append(contentsOf: buffer[0..<n])
        }
        return data.isEmpty ? nil : data
    }

    static func write<T: Encodable>(_ value: T, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
