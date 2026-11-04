import Foundation

public enum SMBError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The server answered with an error status.
    case status(NTStatus)
    /// The TCP connection could not be established (`code` is an errno or a getaddrinfo error).
    case connectionFailed(code: Int32, message: String)
    /// An established connection went away.
    case disconnected(String)
    case timedOut
    case cancelled
    /// The server sent something this client can't parse.
    case malformed(String)
    /// The server needs a feature this client doesn't implement.
    case unsupported(String)
    /// A response failed signature verification. The connection is torn down.
    case signatureMismatch
    /// A local file operation failed.
    case localIO(code: Int32, path: String)
    case invalidArgument(String)

    /// Errors after which the connection (or session) must be re-established.
    public var isConnectionLevel: Bool {
        switch self {
        case .connectionFailed, .disconnected, .timedOut, .signatureMismatch, .malformed: true
        case .status(let status): status.invalidatesSession
        default: false
        }
    }

    public var ntStatus: NTStatus? {
        if case .status(let status) = self { return status }
        return nil
    }

    public var description: String {
        switch self {
        case .status(let status): status.message
        case .connectionFailed(_, let message): message
        case .disconnected(let reason): "The connection to the server was lost (\(reason))."
        case .timedOut: "The server did not respond in time."
        case .cancelled: "The operation was cancelled."
        case .malformed(let detail): "The server sent an invalid response (\(detail))."
        case .unsupported(let detail): detail
        case .signatureMismatch: "A response from the server failed signature verification."
        case .localIO(let code, let path): "\(path): \(String(cString: strerror(code)))"
        case .invalidArgument(let detail): detail
        }
    }

    public var errorDescription: String? { description }

    /// Wraps the current `errno` for a failed local file operation.
    static func posix(_ path: String) -> SMBError {
        .localIO(code: errno, path: path)
    }
}
