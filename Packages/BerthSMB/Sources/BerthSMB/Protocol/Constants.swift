import Foundation

enum SMB2Command: UInt16, Sendable {
    case negotiate = 0x0000
    case sessionSetup = 0x0001
    case logoff = 0x0002
    case treeConnect = 0x0003
    case treeDisconnect = 0x0004
    case create = 0x0005
    case close = 0x0006
    case flush = 0x0007
    case read = 0x0008
    case write = 0x0009
    case lock = 0x000A
    case ioctl = 0x000B
    case cancel = 0x000C
    case echo = 0x000D
    case queryDirectory = 0x000E
    case changeNotify = 0x000F
    case queryInfo = 0x0010
    case setInfo = 0x0011
    case oplockBreak = 0x0012
}

enum SMB2HeaderFlag {
    static let serverToRedirector: UInt32 = 0x0000_0001
    static let asyncCommand: UInt32 = 0x0000_0002
    static let relatedOperations: UInt32 = 0x0000_0004
    static let signed: UInt32 = 0x0000_0008
}

/// SMB 2/3 dialect revision.
public struct SMBDialect: RawRepresentable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let smb202 = SMBDialect(rawValue: 0x0202)
    public static let smb210 = SMBDialect(rawValue: 0x0210)
    public static let smb300 = SMBDialect(rawValue: 0x0300)
    public static let smb302 = SMBDialect(rawValue: 0x0302)
    public static let smb311 = SMBDialect(rawValue: 0x0311)

    public static let all: [SMBDialect] = [.smb202, .smb210, .smb300, .smb302, .smb311]

    public static func < (a: SMBDialect, b: SMBDialect) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .smb202: "2.0.2"
        case .smb210: "2.1"
        case .smb300: "3.0"
        case .smb302: "3.0.2"
        case .smb311: "3.1.1"
        default: String(format: "0x%04X", rawValue)
        }
    }

    var isSMB3: Bool { rawValue >= 0x0300 }
}

enum SMB2Capability {
    static let dfs: UInt32 = 0x0000_0001
    static let leasing: UInt32 = 0x0000_0002
    static let largeMTU: UInt32 = 0x0000_0004
    static let multiChannel: UInt32 = 0x0000_0008
    static let persistentHandles: UInt32 = 0x0000_0010
    static let directoryLeasing: UInt32 = 0x0000_0020
    static let encryption: UInt32 = 0x0000_0040
}

enum SMB2SecurityMode {
    static let signingEnabled: UInt16 = 0x0001
    static let signingRequired: UInt16 = 0x0002
}

enum SMB2SessionFlag {
    static let isGuest: UInt16 = 0x0001
    static let isNull: UInt16 = 0x0002
    static let encryptData: UInt16 = 0x0004
}

enum SMB2ShareFlag {
    static let dfs: UInt32 = 0x0000_0001
    static let encryptData: UInt32 = 0x0000_8000
}

/// Negotiate context types (3.1.1).
enum SMB2NegotiateContext {
    static let preauthIntegrity: UInt16 = 0x0001
    static let encryption: UInt16 = 0x0002
    static let signing: UInt16 = 0x0008
}

public enum SMBCipher: UInt16, Sendable, CustomStringConvertible {
    case aes128CCM = 0x0001
    case aes128GCM = 0x0002
    case aes256CCM = 0x0003
    case aes256GCM = 0x0004

    var keyBits: Int { self == .aes256GCM || self == .aes256CCM ? 256 : 128 }
    var isGCM: Bool { self == .aes128GCM || self == .aes256GCM }

    public var description: String {
        switch self {
        case .aes128CCM: "AES-128-CCM"
        case .aes128GCM: "AES-128-GCM"
        case .aes256CCM: "AES-256-CCM"
        case .aes256GCM: "AES-256-GCM"
        }
    }
}

public enum SMBSigningAlgorithm: UInt16, Sendable, CustomStringConvertible {
    case hmacSHA256 = 0x0000
    case aesCMAC = 0x0001
    case aesGMAC = 0x0002

    public var description: String {
        switch self {
        case .hmacSHA256: "HMAC-SHA256"
        case .aesCMAC: "AES-CMAC"
        case .aesGMAC: "AES-GMAC"
        }
    }
}

/// Access mask bits (MS-SMB2 2.2.13.1).
struct SMBAccess: OptionSet, Sendable {
    let rawValue: UInt32

    static let readData = SMBAccess(rawValue: 0x0000_0001)          // FILE_LIST_DIRECTORY on directories
    static let writeData = SMBAccess(rawValue: 0x0000_0002)         // FILE_ADD_FILE
    static let appendData = SMBAccess(rawValue: 0x0000_0004)        // FILE_ADD_SUBDIRECTORY
    static let readEA = SMBAccess(rawValue: 0x0000_0008)
    static let writeEA = SMBAccess(rawValue: 0x0000_0010)
    static let execute = SMBAccess(rawValue: 0x0000_0020)           // FILE_TRAVERSE
    static let deleteChild = SMBAccess(rawValue: 0x0000_0040)
    static let readAttributes = SMBAccess(rawValue: 0x0000_0080)
    static let writeAttributes = SMBAccess(rawValue: 0x0000_0100)
    static let delete = SMBAccess(rawValue: 0x0001_0000)
    static let readControl = SMBAccess(rawValue: 0x0002_0000)
    static let synchronize = SMBAccess(rawValue: 0x0010_0000)
    static let maximumAllowed = SMBAccess(rawValue: 0x0200_0000)
    static let genericRead = SMBAccess(rawValue: 0x8000_0000)
    static let genericWrite = SMBAccess(rawValue: 0x4000_0000)
}

struct SMBShareAccess: OptionSet, Sendable {
    let rawValue: UInt32
    static let read = SMBShareAccess(rawValue: 0x1)
    static let write = SMBShareAccess(rawValue: 0x2)
    static let delete = SMBShareAccess(rawValue: 0x4)
    static let all: SMBShareAccess = [.read, .write, .delete]
}

enum SMBCreateDisposition: UInt32, Sendable {
    case supersede = 0
    case open = 1
    case create = 2
    case openIf = 3
    case overwrite = 4
    case overwriteIf = 5
}

struct SMBCreateOptions: OptionSet, Sendable {
    let rawValue: UInt32
    static let directoryFile = SMBCreateOptions(rawValue: 0x0000_0001)
    static let writeThrough = SMBCreateOptions(rawValue: 0x0000_0002)
    static let sequentialOnly = SMBCreateOptions(rawValue: 0x0000_0004)
    static let nonDirectoryFile = SMBCreateOptions(rawValue: 0x0000_0040)
    static let randomAccess = SMBCreateOptions(rawValue: 0x0000_0800)
    static let deleteOnClose = SMBCreateOptions(rawValue: 0x0000_1000)
    static let openReparsePoint = SMBCreateOptions(rawValue: 0x0020_0000)
}

/// File attributes (MS-FSCC 2.6).
public struct SMBFileAttributes: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let readOnly = SMBFileAttributes(rawValue: 0x0000_0001)
    public static let hidden = SMBFileAttributes(rawValue: 0x0000_0002)
    public static let system = SMBFileAttributes(rawValue: 0x0000_0004)
    public static let directory = SMBFileAttributes(rawValue: 0x0000_0010)
    public static let archive = SMBFileAttributes(rawValue: 0x0000_0020)
    public static let normal = SMBFileAttributes(rawValue: 0x0000_0080)
    public static let temporary = SMBFileAttributes(rawValue: 0x0000_0100)
    public static let sparse = SMBFileAttributes(rawValue: 0x0000_0200)
    public static let reparsePoint = SMBFileAttributes(rawValue: 0x0000_0400)
    public static let compressed = SMBFileAttributes(rawValue: 0x0000_0800)
    public static let offline = SMBFileAttributes(rawValue: 0x0000_1000)
    public static let notContentIndexed = SMBFileAttributes(rawValue: 0x0000_2000)
    public static let encrypted = SMBFileAttributes(rawValue: 0x0000_4000)
}

enum SMBInfoType: UInt8 {
    case file = 0x01
    case fileSystem = 0x02
    case security = 0x03
    case quota = 0x04
}

enum SMBFileInfoClass: UInt8 {
    case basic = 4               // FileBasicInformation
    case standard = 5            // FileStandardInformation
    case fileID = 6              // FileInternalInformation (the file id)
    case rename = 10             // FileRenameInformation
    case disposition = 13        // FileDispositionInformation
    case all = 18                // FileAllInformation
    case endOfFile = 20          // FileEndOfFileInformation
    case idFullDirectory = 38    // FileIdFullDirectoryInformation
}

enum SMBFSInfoClass: UInt8 {
    case volume = 1              // FileFsVolumeInformation
    case size = 3                // FileFsSizeInformation
    case attribute = 5           // FileFsAttributeInformation
    case fullSize = 7            // FileFsFullSizeInformation
}

enum SMBQueryDirectoryFlag {
    static let restartScans: UInt8 = 0x01
    static let returnSingleEntry: UInt8 = 0x02
    static let indexSpecified: UInt8 = 0x04
    static let reopen: UInt8 = 0x10
}

/// Change notify completion filter (MS-SMB2 2.2.35).
enum SMBNotifyFilter {
    static let fileName: UInt32 = 0x0000_0001
    static let dirName: UInt32 = 0x0000_0002
    static let attributes: UInt32 = 0x0000_0004
    static let size: UInt32 = 0x0000_0008
    static let lastWrite: UInt32 = 0x0000_0010
    static let creation: UInt32 = 0x0000_0040
    static let allChanges: UInt32 = fileName | dirName | attributes | size | lastWrite | creation
}

/// A 16-byte SMB2 file handle.
struct SMBFileID: Hashable, Sendable {
    var persistent: UInt64
    var volatile: UInt64

    /// Placeholder meaning "the handle from the previous request in this compound".
    static let related = SMBFileID(persistent: .max, volatile: .max)
}

enum SMB2 {
    static let headerSize = 64
    /// The protocol's credit unit: one credit per 64 KiB of payload.
    static let creditUnit = 65_536
    static let unsolicitedMessageID: UInt64 = .max

    static func creditCharge(forPayload bytes: Int) -> Int {
        max(1, (bytes - 1) / creditUnit + 1)
    }
}
