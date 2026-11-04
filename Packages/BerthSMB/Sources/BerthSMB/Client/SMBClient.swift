import Foundation
import Synchronization

/// A file on an SMB share. Paths are "/"-separated and relative to the share root ("" is the root).
public struct SMBItem: Sendable, Hashable {
    public var path: String
    public var name: String
    /// The server's file id (inode / NTFS file reference). 0 when the server doesn't report one.
    public var fileID: UInt64
    public var isDirectory: Bool
    public var size: Int64
    public var allocationSize: Int64
    public var attributes: SMBFileAttributes
    /// Raw FILETIME values (100 ns resolution), handy for exact version comparisons.
    public var creationTime: UInt64
    public var lastAccessTime: UInt64
    public var lastWriteTime: UInt64
    public var changeTime: UInt64

    public var creationDate: Date? { FileTime.date(creationTime) }
    public var modificationDate: Date? { FileTime.date(lastWriteTime) }
    public var changeDate: Date? { FileTime.date(changeTime) }
    public var lastAccessDate: Date? { FileTime.date(lastAccessTime) }
    public var isHidden: Bool { attributes.contains(.hidden) }
    public var isReadOnly: Bool { attributes.contains(.readOnly) }
    public var isReparsePoint: Bool { attributes.contains(.reparsePoint) }

    /// For tests and previews.
    public init(path: String, fileID: UInt64, isDirectory: Bool, size: Int64 = 0, attributes: SMBFileAttributes = [],
                creationTime: UInt64 = 0, lastAccessTime: UInt64 = 0, lastWriteTime: UInt64 = 0, changeTime: UInt64 = 0) {
        self.path = SMBPath.normalize(path)
        self.name = SMBPath.lastComponent(path)
        self.fileID = fileID
        self.isDirectory = isDirectory
        self.size = isDirectory ? 0 : size
        self.allocationSize = self.size
        self.attributes = isDirectory ? attributes.union(.directory) : attributes
        self.creationTime = creationTime
        self.lastAccessTime = lastAccessTime
        self.lastWriteTime = lastWriteTime
        self.changeTime = changeTime
    }

    init(path: String, stat: SMBFileStat, fileID: UInt64) {
        self.path = path
        self.name = SMBPath.lastComponent(path)
        self.fileID = fileID
        self.isDirectory = stat.attributes.contains(.directory)
        self.size = Int64(clamping: stat.endOfFile)
        self.allocationSize = Int64(clamping: stat.allocationSize)
        self.attributes = stat.attributes
        self.creationTime = stat.creationTime
        self.lastAccessTime = stat.lastAccessTime
        self.lastWriteTime = stat.lastWriteTime
        self.changeTime = stat.changeTime
    }
}

public struct SMBSpaceInfo: Sendable, Hashable {
    public var totalBytes: Int64
    public var availableBytes: Int64
}

/// A change reported by CHANGE_NOTIFY, with paths relative to the share root.
public enum SMBChange: Sendable, Hashable {
    case added(String)
    case removed(String)
    case modified(String)
    case renamed(from: String, to: String)
    /// The server dropped events (too many changes); rescan everything under the watched folder.
    case overflow

    /// The directories whose listings may have changed.
    public var affectedDirectories: [String] {
        switch self {
        case .added(let p), .removed(let p), .modified(let p): [SMBPath.parent(p)]
        case .renamed(let from, let to): [SMBPath.parent(from), SMBPath.parent(to)]
        case .overflow: []
        }
    }
}

/// "/"-separated share paths.
public enum SMBPath {
    public static func normalize(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    public static func join(_ parent: String, _ name: String) -> String {
        let p = normalize(parent)
        return p.isEmpty ? normalize(name) : p + "/" + normalize(name)
    }

    public static func parent(_ path: String) -> String {
        let parts = normalize(path).split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }

    public static func lastComponent(_ path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? ""
    }

    /// Backslash-separated, NFC, as the server expects.
    static func wire(_ path: String) -> String {
        normalize(path).replacingOccurrences(of: "/", with: "\\").smbNormalized
    }

    static func fromWire(_ path: String) -> String {
        normalize(path.replacingOccurrences(of: "\\", with: "/"))
    }
}

/// A connected share: one TCP connection, one session, one tree.
final class SMBTree: Sendable {
    let connection: SMBConnection
    let treeID: UInt32
    let info: SMBConnectionInfo
    let readSize: Int
    let writeSize: Int
    let transactSize: Int
    let tuning: SMBClient.Tuning

    init(connection: SMBConnection, treeID: UInt32, info: SMBConnectionInfo, tuning: SMBClient.Tuning) {
        let unit = info.supportsMultiCredit ? Int.max : SMB2.creditUnit
        // Keep each request well inside the credit window so I/O can always be scheduled.
        let creditCap = max(1, tuning.targetCredits / 4) * SMB2.creditUnit
        let read = max(4096, min(tuning.ioSize, info.maxReadSize, unit, creditCap))
        let write = max(4096, min(tuning.ioSize, info.maxWriteSize, unit, creditCap))
        var info = info
        info.ioSize = min(read, write)
        self.connection = connection
        self.treeID = treeID
        self.info = info
        self.tuning = tuning
        self.readSize = read
        self.writeSize = write
        self.transactSize = max(4096, min(info.maxTransactSize, unit, creditCap))
    }

    func send(_ request: SMBRequest) async throws -> SMBMessage {
        var request = request
        request.treeID = treeID
        return try await connection.send(request)
    }

    /// Sends a related compound (one round trip). Returns every response, failed or not.
    func compound(_ requests: [SMBRequest]) async throws -> [SMBMessage] {
        let tagged = requests.map { request -> SMBRequest in
            var request = request
            request.treeID = treeID
            return request
        }
        let responses = try await connection.send(tagged).responses
        guard responses.count == requests.count else { throw SMBError.malformed("compound response count") }
        return responses
    }

    /// Closes a handle from a fresh task, so it goes out even if the caller was cancelled.
    func closeDetached(_ fileID: SMBFileID) {
        Task { _ = try? await self.send(Requests.close(fileID)) }
    }
}

/// High-performance SMB 2/3 client for one share.
///
/// Thread-safe; share one instance between any number of concurrent tasks. Connection loss is
/// handled transparently: the next operation reconnects, and idempotent operations (stat, list,
/// read) are retried once on a fresh connection.
public final class SMBClient: Sendable {
    public struct Tuning: Sendable, Hashable, Codable {
        /// Bytes per READ/WRITE request (clamped to the server's limits).
        public var ioSize: Int = 1 << 20
        /// Requests in flight per transfer. ioSize × ioDepth should cover the bandwidth-delay product.
        public var ioDepth: Int = 16
        /// Credit window the client asks the server to keep open.
        public var targetCredits: Int = 512
        /// QUERY_DIRECTORY output buffer.
        public var directoryBufferSize: Int = 256 * 1024
        public var socketBufferSize: Int = 4 << 20
        /// Files transferred in parallel by recursive operations.
        public var parallelFiles: Int = 8

        public init() {}

        public static let lan = Tuning()

        /// High latency links (Tailscale, VPN, WAN): more data in flight.
        public static var wan: Tuning {
            var t = Tuning()
            t.ioSize = 1 << 20
            t.ioDepth = 32
            t.targetCredits = 1024
            t.socketBufferSize = 8 << 20
            return t
        }
    }

    public struct Configuration: Sendable, Hashable {
        public var host: String
        public var port: Int
        public var share: String
        public var credentials: SMBCredentials
        public var workstation: String
        public var connectTimeout: Duration
        public var requestTimeout: Duration
        public var requireSigning: Bool
        public var requireEncryption: Bool
        public var dialects: [SMBDialect]
        public var tuning: Tuning

        public init(host: String, port: Int = 445, share: String, credentials: SMBCredentials,
                    workstation: String = "BERTH", connectTimeout: Duration = .seconds(10),
                    requestTimeout: Duration = .seconds(30), requireSigning: Bool = false,
                    requireEncryption: Bool = false, dialects: [SMBDialect] = SMBDialect.all,
                    tuning: Tuning = Tuning()) {
            self.host = host
            self.port = port
            self.share = share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
            self.credentials = credentials
            self.workstation = workstation
            self.connectTimeout = connectTimeout
            self.requestTimeout = requestTimeout
            self.requireSigning = requireSigning
            self.requireEncryption = requireEncryption
            self.dialects = dialects
            self.tuning = tuning
        }
    }

    public let configuration: Configuration

    private struct State {
        var tree: SMBTree?
        var connecting: Task<SMBTree, Error>?
        var closed = false
    }

    private let state = Mutex(State())

    public init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        state.withLock { s in
            s.connecting?.cancel()
            s.tree?.connection.close()
        }
    }

    /// Connects (or reuses the live connection) and returns what was negotiated.
    @discardableResult
    public func connect() async throws -> SMBConnectionInfo {
        try await tree().info
    }

    /// The live connection's parameters, if connected.
    public var connectionInfo: SMBConnectionInfo? {
        state.withLock { s in
            guard let tree = s.tree, !tree.connection.isClosed else { return nil }
            return tree.info
        }
    }

    public var isConnected: Bool { connectionInfo != nil }

    /// Logs off and closes the connection. The client can connect again afterwards.
    public func disconnect() async {
        let tree = state.withLock { s -> SMBTree? in
            s.connecting?.cancel()
            s.connecting = nil
            let tree = s.tree
            s.tree = nil
            return tree
        }
        if let tree {
            _ = try? await tree.send(Requests.treeDisconnect())
            await tree.connection.logoff()
            tree.connection.close()
        }
    }

    /// Drops the current connection without a goodbye (the network changed, the server moved…).
    public func reset() {
        let tree = state.withLock { s -> SMBTree? in
            let tree = s.tree
            s.tree = nil
            return tree
        }
        tree?.connection.close()
    }

    // MARK: Connection management

    func tree() async throws -> SMBTree {
        enum Next { case ready(SMBTree), wait(Task<SMBTree, Error>) }
        let configuration = self.configuration
        let next: Next = try state.withLock { s in
            if let tree = s.tree, !tree.connection.isClosed { return .ready(tree) }
            s.tree = nil
            if let task = s.connecting { return .wait(task) }
            guard !s.closed else { throw SMBError.disconnected("the client was closed") }
            let task = Task { try await SMBClient.establish(configuration) }
            s.connecting = task
            return .wait(task)
        }
        switch next {
        case .ready(let tree):
            return tree
        case .wait(let task):
            do {
                let tree = try await task.value
                state.withLock { s in
                    if s.connecting == task {
                        s.connecting = nil
                        s.tree = tree
                    }
                }
                return tree
            } catch {
                state.withLock { s in
                    if s.connecting == task { s.connecting = nil }
                }
                throw error
            }
        }
    }

    private func invalidate(_ tree: SMBTree) {
        state.withLock { s in
            if s.tree === tree { s.tree = nil }
        }
        tree.connection.close()
    }

    /// Runs `body` against the live tree; for idempotent work, retries once on a fresh
    /// connection when the old one turned out to be dead.
    func perform<T>(idempotent: Bool, _ body: (SMBTree) async throws -> T) async throws -> T {
        let tree = try await self.tree()
        do {
            return try await body(tree)
        } catch let error as SMBError where error.isConnectionLevel {
            invalidate(tree)
            guard idempotent else { throw error }
            return try await body(try await self.tree())
        }
    }

    static func establish(_ configuration: Configuration) async throws -> SMBTree {
        let tuning = configuration.tuning
        let connection = try SMBConnection.open(
            host: configuration.host, port: configuration.port, connectTimeout: configuration.connectTimeout,
            socketBufferSize: tuning.socketBufferSize,
            configuration: SMBConnection.Configuration(requestTimeout: configuration.requestTimeout,
                                                       targetCredits: tuning.targetCredits))
        do {
            let policy = SecurityPolicy(requireSigning: configuration.requireSigning,
                                        requireEncryption: configuration.requireEncryption)
            let negotiated = try await connection.negotiate(dialects: configuration.dialects, policy: policy)
            let session = try await connection.authenticate(
                credentials: configuration.credentials, workstation: configuration.workstation,
                negotiated: negotiated, policy: policy)
            let tree = try await connection.treeConnect(host: configuration.host, share: configuration.share)

            let response = negotiated.response
            let multiCredit = response.dialect != .smb202 && response.capabilities & SMB2Capability.largeMTU != 0
            let security = connection.security
            let writeAccess = SMBAccess.writeData.rawValue | SMBAccess.appendData.rawValue
                | SMBAccess.genericWrite.rawValue | SMBAccess.maximumAllowed.rawValue
            let info = SMBConnectionInfo(
                dialect: response.dialect,
                signing: (security?.signRequests == true && security?.encryptRequests != true) ? security?.signingAlgorithm : nil,
                encryption: security?.encryptRequests == true ? security?.cipher : nil,
                maxReadSize: response.maxReadSize, maxWriteSize: response.maxWriteSize,
                maxTransactSize: response.maxTransactSize, ioSize: 0, supportsMultiCredit: multiCredit,
                isGuest: session.isGuest, isAnonymous: session.isAnonymous,
                isReadOnly: tree.response.maximalAccess & writeAccess == 0,
                serverGUID: UUID(uuid: Self.uuidTuple(response.serverGUID)),
                remote: connection.socket.remoteDescription)
            return SMBTree(connection: connection, treeID: tree.treeID, info: info, tuning: tuning)
        } catch {
            connection.close()
            throw error
        }
    }

    private static func uuidTuple(_ b: [UInt8]) -> uuid_t {
        let x = b.count == 16 ? b : [UInt8](repeating: 0, count: 16)
        return (x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7], x[8], x[9], x[10], x[11], x[12], x[13], x[14], x[15])
    }
}
