import Foundation
import NetFS

public struct MountError: LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case authentication
        case passwordExpired
        case hostUnreachable
        case shareNotFound
        case timedOut
        case cancelled
        case alreadyMounted
        case mountPointUnavailable
        case invalidConfiguration
        case other
    }

    public var kind: Kind
    public var code: Int32
    public var message: String

    public init(kind: Kind, code: Int32 = 0, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// Maps NetFS return values (errno when positive, OSStatus when negative).
    public static func from(status: Int32) -> MountError {
        switch status {
        case EAUTH, EACCES, EPERM, -6004 /* guest not supported */, -5999 /* account restricted */, -5997 /* no auth mech */:
            return MountError(kind: .authentication, code: status,
                              message: status == -6004 ? "The server does not allow guest access." : "The server rejected the user name or password.")
        case -5045, -5046:
            return MountError(kind: .passwordExpired, code: status, message: "The password has expired or must be changed on the server.")
        case EHOSTUNREACH, ENETUNREACH, ECONNREFUSED, EHOSTDOWN, ENETDOWN, ECONNRESET:
            return MountError(kind: .hostUnreachable, code: status, message: "The server could not be reached (\(String(cString: strerror(status)))).")
        case ETIMEDOUT:
            return MountError(kind: .timedOut, code: status, message: "The server did not respond in time.")
        case ENOENT, -6003, -5998:
            return MountError(kind: .shareNotFound, code: status, message: "The share does not exist on the server, or you have no access to it.")
        case EEXIST:
            return MountError(kind: .alreadyMounted, code: status, message: "The share is already mounted.")
        case EBUSY, ENOTEMPTY:
            return MountError(kind: .mountPointUnavailable, code: status, message: "The mount point is in use or not empty.")
        case -128, ECANCELED:
            return MountError(kind: .cancelled, code: status, message: "The mount was cancelled.")
        case -5996:
            return MountError(kind: .other, code: status, message: "No SMB protocol version in common with the server. Try the Compatibility preset.")
        case -6602:
            return MountError(kind: .other, code: status, message: "The server refused the mount.")
        default:
            if status > 0 {
                return MountError(kind: .other, code: status, message: String(cString: strerror(status)))
            }
            return MountError(kind: .other, code: status, message: "Mount failed (error \(status)).")
        }
    }
}

public struct MountRequest: Sendable {
    public var url: URL
    public var mountPoint: String?
    public var username: String?
    public var password: String?
    public var guest: Bool
    public var options: MountOptions
    public var timeout: Duration

    public init(url: URL, mountPoint: String?, username: String?, password: String?, guest: Bool,
                options: MountOptions, timeout: Duration) {
        self.url = url
        self.mountPoint = mountPoint
        self.username = username
        self.password = password
        self.guest = guest
        self.options = options
        self.timeout = timeout
    }
}

/// NetFS wrapper. Never shows UI: Berth owns the credential flow.
public enum Mounter {
    private static let queue = DispatchQueue(label: "app.berth.netfs", qos: .userInitiated)

    /// Mounts and returns the mount point.
    public static func mount(_ request: MountRequest) async throws(MountError) -> String {
        if let custom = request.mountPoint {
            try prepareMountPoint(custom)
        }

        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "NoUI"
        if request.guest { openOptions["Guest"] = true }
        if request.options.forceNewSession { openOptions["ForceNewSession"] = true }

        let mountOptions = NSMutableDictionary()
        var flags: Int32 = 0
        if request.options.hideFromFinder { flags |= MNT_DONTBROWSE }
        if request.options.readOnly { flags |= MNT_RDONLY }
        if request.options.noSetUID { flags |= MNT_NOSUID | MNT_NODEV }
        if flags != 0 { mountOptions["MountFlags"] = NSNumber(value: flags) }
        if request.options.softMount { mountOptions["SoftMount"] = true }
        if request.mountPoint != nil { mountOptions["MountAtMountDir"] = true }

        let mountURL = request.mountPoint.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let user = request.username
        let password = request.password

        final class RequestHolder: @unchecked Sendable { var id: AsyncRequestID? }
        let holder = RequestHolder()
        let dictionaries = UncheckedSendable((openOptions, mountOptions))
        let box = OnceBox<Result<String, MountError>>()

        let result: Result<String, MountError> = await withCheckedContinuation { continuation in
            box.setHandler { continuation.resume(returning: $0) }
            queue.async {
                var requestID: AsyncRequestID?
                let status = NetFSMountURLAsync(
                    request.url as CFURL,
                    mountURL as CFURL?,
                    user as CFString?,
                    password as CFString?,
                    dictionaries.value.0,
                    dictionaries.value.1,
                    &requestID,
                    queue
                ) { status, _, mountpoints in
                    if status == 0 {
                        let points = (mountpoints as? [String]) ?? []
                        if let first = points.first {
                            box.fire(.success(first))
                        } else {
                            box.fire(.failure(MountError(kind: .other, message: "The server returned no mount point.")))
                        }
                    } else {
                        box.fire(.failure(MountError.from(status: status)))
                    }
                }
                holder.id = requestID
                if status != 0 { box.fire(.failure(MountError.from(status: status))) }
            }
            queue.asyncAfter(deadline: .now() + request.timeout.timeInterval) {
                if let id = holder.id { _ = NetFSMountURLCancel(id) }
                box.fire(.failure(MountError(kind: .timedOut, code: ETIMEDOUT, message: "The mount timed out.")))
            }
        }
        return try result.get()
    }

    /// Custom mount points must exist, be directories and be empty.
    static func prepareMountPoint(_ path: String) throws(MountError) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw MountError(kind: .mountPointUnavailable, message: "“\(path)” exists and is not a folder.")
            }
            let contents = (try? fm.contentsOfDirectory(atPath: path))?.filter { $0 != ".DS_Store" && $0 != ".localized" } ?? []
            guard contents.isEmpty else {
                throw MountError(kind: .mountPointUnavailable, message: "The mount folder “\(path)” is not empty.")
            }
        } else {
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                throw MountError(kind: .mountPointUnavailable, message: "Could not create “\(path)”: \(error.localizedDescription)")
            }
        }
    }
}

/// Escape hatch for passing values that are only touched on one queue across a `@Sendable` boundary.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
