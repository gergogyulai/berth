import Foundation

/// An NTSTATUS code as returned in the SMB2 header.
public struct NTStatus: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }

    public static let success = NTStatus(0x0000_0000)
    public static let pending = NTStatus(0x0000_0103)
    public static let notifyCleanup = NTStatus(0x0000_010B)
    public static let notifyEnumDir = NTStatus(0x0000_010C)
    public static let bufferOverflow = NTStatus(0x8000_0005)
    public static let noMoreFiles = NTStatus(0x8000_0006)
    public static let invalidHandle = NTStatus(0xC000_0008)
    public static let invalidParameter = NTStatus(0xC000_000D)
    public static let noSuchFile = NTStatus(0xC000_000F)
    public static let invalidDeviceRequest = NTStatus(0xC000_0010)
    public static let endOfFile = NTStatus(0xC000_0011)
    public static let moreProcessingRequired = NTStatus(0xC000_0016)
    public static let accessDenied = NTStatus(0xC000_0022)
    public static let bufferTooSmall = NTStatus(0xC000_0023)
    public static let objectNameInvalid = NTStatus(0xC000_0033)
    public static let objectNameNotFound = NTStatus(0xC000_0034)
    public static let objectNameCollision = NTStatus(0xC000_0035)
    public static let objectPathInvalid = NTStatus(0xC000_0039)
    public static let objectPathNotFound = NTStatus(0xC000_003A)
    public static let objectPathSyntaxBad = NTStatus(0xC000_003B)
    public static let sharingViolation = NTStatus(0xC000_0043)
    public static let deletePending = NTStatus(0xC000_0056)
    public static let privilegeNotHeld = NTStatus(0xC000_0061)
    public static let wrongPassword = NTStatus(0xC000_006A)
    public static let logonFailure = NTStatus(0xC000_006D)
    public static let accountRestriction = NTStatus(0xC000_006E)
    public static let invalidLogonHours = NTStatus(0xC000_006F)
    public static let invalidWorkstation = NTStatus(0xC000_0070)
    public static let passwordExpired = NTStatus(0xC000_0071)
    public static let accountDisabled = NTStatus(0xC000_0072)
    public static let diskFull = NTStatus(0xC000_007F)
    public static let insufficientResources = NTStatus(0xC000_009A)
    public static let mediaWriteProtected = NTStatus(0xC000_00A2)
    public static let fileIsADirectory = NTStatus(0xC000_00BA)
    public static let notSupported = NTStatus(0xC000_00BB)
    public static let networkNameDeleted = NTStatus(0xC000_00C9)
    public static let networkAccessDenied = NTStatus(0xC000_00CA)
    public static let badNetworkName = NTStatus(0xC000_00CC)
    public static let requestNotAccepted = NTStatus(0xC000_00D0)
    public static let notSameDevice = NTStatus(0xC000_00D4)
    public static let fileRenamed = NTStatus(0xC000_00D5)
    public static let directoryNotEmpty = NTStatus(0xC000_0101)
    public static let notADirectory = NTStatus(0xC000_0103)
    public static let cancelled = NTStatus(0xC000_0120)
    public static let cannotDelete = NTStatus(0xC000_0121)
    public static let fileClosed = NTStatus(0xC000_0128)
    public static let logonTypeNotGranted = NTStatus(0xC000_015B)
    public static let accountExpired = NTStatus(0xC000_0193)
    public static let userSessionDeleted = NTStatus(0xC000_0203)
    public static let connectionDisconnected = NTStatus(0xC000_020C)
    public static let connectionReset = NTStatus(0xC000_020D)
    public static let passwordMustChange = NTStatus(0xC000_0224)
    public static let accountLockedOut = NTStatus(0xC000_0234)
    public static let pathNotCovered = NTStatus(0xC000_0257)
    public static let networkSessionExpired = NTStatus(0xC000_035C)
    public static let smbBadClusterDialect = NTStatus(0xC000_A0C1)

    /// 0 success, 1 informational, 2 warning, 3 error.
    public var severity: UInt32 { rawValue >> 30 }
    public var isSuccess: Bool { rawValue == 0 }
    public var isError: Bool { severity == 3 }

    /// Statuses after which the session (or the whole connection) can't be used any more.
    public var invalidatesSession: Bool {
        self == .networkSessionExpired || self == .userSessionDeleted || self == .networkNameDeleted
            || self == .connectionDisconnected || self == .connectionReset
    }

    public var isAuthenticationFailure: Bool {
        [.logonFailure, .wrongPassword, .accountRestriction, .invalidLogonHours, .invalidWorkstation,
         .accountDisabled, .accountExpired, .accountLockedOut, .logonTypeNotGranted].contains(self)
    }

    public var isPasswordExpired: Bool { self == .passwordExpired || self == .passwordMustChange }

    public var isNotFound: Bool {
        self == .objectNameNotFound || self == .objectPathNotFound || self == .noSuchFile || self == .badNetworkName
    }

    public var name: String {
        switch self {
        case .success: "STATUS_SUCCESS"
        case .pending: "STATUS_PENDING"
        case .notifyCleanup: "STATUS_NOTIFY_CLEANUP"
        case .notifyEnumDir: "STATUS_NOTIFY_ENUM_DIR"
        case .bufferOverflow: "STATUS_BUFFER_OVERFLOW"
        case .noMoreFiles: "STATUS_NO_MORE_FILES"
        case .invalidHandle: "STATUS_INVALID_HANDLE"
        case .invalidParameter: "STATUS_INVALID_PARAMETER"
        case .noSuchFile: "STATUS_NO_SUCH_FILE"
        case .invalidDeviceRequest: "STATUS_INVALID_DEVICE_REQUEST"
        case .endOfFile: "STATUS_END_OF_FILE"
        case .moreProcessingRequired: "STATUS_MORE_PROCESSING_REQUIRED"
        case .accessDenied: "STATUS_ACCESS_DENIED"
        case .bufferTooSmall: "STATUS_BUFFER_TOO_SMALL"
        case .objectNameInvalid: "STATUS_OBJECT_NAME_INVALID"
        case .objectNameNotFound: "STATUS_OBJECT_NAME_NOT_FOUND"
        case .objectNameCollision: "STATUS_OBJECT_NAME_COLLISION"
        case .objectPathInvalid: "STATUS_OBJECT_PATH_INVALID"
        case .objectPathNotFound: "STATUS_OBJECT_PATH_NOT_FOUND"
        case .objectPathSyntaxBad: "STATUS_OBJECT_PATH_SYNTAX_BAD"
        case .sharingViolation: "STATUS_SHARING_VIOLATION"
        case .deletePending: "STATUS_DELETE_PENDING"
        case .privilegeNotHeld: "STATUS_PRIVILEGE_NOT_HELD"
        case .wrongPassword: "STATUS_WRONG_PASSWORD"
        case .logonFailure: "STATUS_LOGON_FAILURE"
        case .accountRestriction: "STATUS_ACCOUNT_RESTRICTION"
        case .invalidLogonHours: "STATUS_INVALID_LOGON_HOURS"
        case .invalidWorkstation: "STATUS_INVALID_WORKSTATION"
        case .passwordExpired: "STATUS_PASSWORD_EXPIRED"
        case .accountDisabled: "STATUS_ACCOUNT_DISABLED"
        case .diskFull: "STATUS_DISK_FULL"
        case .insufficientResources: "STATUS_INSUFFICIENT_RESOURCES"
        case .mediaWriteProtected: "STATUS_MEDIA_WRITE_PROTECTED"
        case .fileIsADirectory: "STATUS_FILE_IS_A_DIRECTORY"
        case .notSupported: "STATUS_NOT_SUPPORTED"
        case .networkNameDeleted: "STATUS_NETWORK_NAME_DELETED"
        case .networkAccessDenied: "STATUS_NETWORK_ACCESS_DENIED"
        case .badNetworkName: "STATUS_BAD_NETWORK_NAME"
        case .requestNotAccepted: "STATUS_REQUEST_NOT_ACCEPTED"
        case .notSameDevice: "STATUS_NOT_SAME_DEVICE"
        case .fileRenamed: "STATUS_FILE_RENAMED"
        case .directoryNotEmpty: "STATUS_DIRECTORY_NOT_EMPTY"
        case .notADirectory: "STATUS_NOT_A_DIRECTORY"
        case .cancelled: "STATUS_CANCELLED"
        case .cannotDelete: "STATUS_CANNOT_DELETE"
        case .fileClosed: "STATUS_FILE_CLOSED"
        case .logonTypeNotGranted: "STATUS_LOGON_TYPE_NOT_GRANTED"
        case .accountExpired: "STATUS_ACCOUNT_EXPIRED"
        case .userSessionDeleted: "STATUS_USER_SESSION_DELETED"
        case .connectionDisconnected: "STATUS_CONNECTION_DISCONNECTED"
        case .connectionReset: "STATUS_CONNECTION_RESET"
        case .passwordMustChange: "STATUS_PASSWORD_MUST_CHANGE"
        case .accountLockedOut: "STATUS_ACCOUNT_LOCKED_OUT"
        case .pathNotCovered: "STATUS_PATH_NOT_COVERED"
        case .networkSessionExpired: "STATUS_NETWORK_SESSION_EXPIRED"
        case .smbBadClusterDialect: "STATUS_SMB_BAD_CLUSTER_DIALECT"
        default: String(format: "NTSTATUS 0x%08X", rawValue)
        }
    }

    /// A sentence suitable for the UI.
    public var message: String {
        switch self {
        case .logonFailure, .wrongPassword: "The server rejected the user name or password."
        case .accountRestriction, .invalidLogonHours, .invalidWorkstation, .logonTypeNotGranted:
            "This account is not allowed to sign in from here."
        case .accountDisabled: "The account is disabled on the server."
        case .accountExpired: "The account has expired on the server."
        case .accountLockedOut: "The account is locked out on the server."
        case .passwordExpired, .passwordMustChange: "The password has expired or must be changed on the server."
        case .badNetworkName: "The share does not exist on the server."
        case .accessDenied, .networkAccessDenied: "Access was denied."
        case .objectNameNotFound, .objectPathNotFound, .noSuchFile: "The item does not exist on the server."
        case .objectNameCollision: "An item with that name already exists."
        case .objectNameInvalid, .objectPathInvalid, .objectPathSyntaxBad: "The name is not valid on the server."
        case .sharingViolation: "The item is in use by another program."
        case .directoryNotEmpty: "The folder is not empty."
        case .diskFull: "The server is out of space."
        case .mediaWriteProtected: "The share is read-only."
        case .notSupported, .invalidDeviceRequest: "The server does not support this operation."
        case .networkSessionExpired, .userSessionDeleted: "The server ended the session."
        case .networkNameDeleted: "The share was disconnected by the server."
        case .pathNotCovered: "The share is a DFS link, which Berth's SMB client does not follow."
        default: "The server returned \(name)."
        }
    }

    public var description: String { name }
}
