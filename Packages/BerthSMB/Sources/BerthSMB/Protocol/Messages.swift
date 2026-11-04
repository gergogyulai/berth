import Foundation

// MARK: - Requests

/// How long the connection waits for a response before declaring the server dead.
enum SMBRequestTimeout: Sendable {
    /// The connection's configured request timeout.
    case standard
    /// No timeout (CHANGE_NOTIFY can legitimately take hours).
    case unlimited
}

/// A fully encoded request. `frame` holds four bytes reserved for the Direct TCP length prefix,
/// then the 64-byte SMB2 header (filled in by the connection), then the body.
struct SMBRequest: Sendable {
    var command: SMB2Command
    var frame: [UInt8]
    /// Credits consumed: one per 64 KiB of payload in either direction.
    var creditCharge: Int
    var treeID: UInt32 = 0
    var timeout: SMBRequestTimeout = .standard

    static let prefixSize = 4
}

struct RequestBuilder {
    var w: ByteWriter
    let command: SMB2Command

    init(_ command: SMB2Command, bodyCapacity: Int = 96) {
        w = ByteWriter(origin: SMBRequest.prefixSize, capacity: SMB2.headerSize + bodyCapacity)
        w.zeros(SMB2.headerSize)
        self.command = command
    }

    mutating func fileID(_ id: SMBFileID) {
        w.u64(id.persistent)
        w.u64(id.volatile)
    }

    func finish(creditCharge: Int = 1, timeout: SMBRequestTimeout = .standard) -> SMBRequest {
        SMBRequest(command: command, frame: w.bytes, creditCharge: creditCharge, timeout: timeout)
    }
}

enum Requests {
    static func negotiate(dialects: [SMBDialect], securityMode: UInt16, capabilities: UInt32,
                          clientGUID: [UInt8], salt: [UInt8]) -> SMBRequest {
        var b = RequestBuilder(.negotiate, bodyCapacity: 160)
        b.w.u16(36)
        b.w.u16(UInt16(dialects.count))
        b.w.u16(securityMode)
        b.w.u16(0)
        b.w.u32(capabilities)
        b.w.append(clientGUID)
        let contextOffsetField = b.w.offset
        b.w.u32(0)
        let wants311 = dialects.contains(.smb311)
        b.w.u16(wants311 ? 3 : 0)
        b.w.u16(0)
        for dialect in dialects { b.w.u16(dialect.rawValue) }

        if wants311 {
            b.w.align(to: 8)
            b.w.set32(UInt32(b.w.offset), at: contextOffsetField)

            // Pre-authentication integrity: SHA-512 with a 32-byte salt.
            var preauth = ByteWriter(capacity: 38)
            preauth.u16(1)
            preauth.u16(UInt16(salt.count))
            preauth.u16(0x0001)
            preauth.append(salt)
            appendContext(&b.w, type: SMB2NegotiateContext.preauthIntegrity, data: preauth.bytes)
            b.w.align(to: 8)

            // Only GCM ciphers: CryptoKit provides hardware AES-GCM; CCM would be software.
            var ciphers = ByteWriter(capacity: 6)
            ciphers.u16(2)
            ciphers.u16(SMBCipher.aes128GCM.rawValue)
            ciphers.u16(SMBCipher.aes256GCM.rawValue)
            appendContext(&b.w, type: SMB2NegotiateContext.encryption, data: ciphers.bytes)
            b.w.align(to: 8)

            var signing = ByteWriter(capacity: 8)
            signing.u16(3)
            signing.u16(SMBSigningAlgorithm.aesGMAC.rawValue)
            signing.u16(SMBSigningAlgorithm.aesCMAC.rawValue)
            signing.u16(SMBSigningAlgorithm.hmacSHA256.rawValue)
            appendContext(&b.w, type: SMB2NegotiateContext.signing, data: signing.bytes)
        }
        return b.finish()
    }

    private static func appendContext(_ w: inout ByteWriter, type: UInt16, data: [UInt8]) {
        w.u16(type)
        w.u16(UInt16(data.count))
        w.u32(0)
        w.append(data)
    }

    static func sessionSetup(blob: [UInt8], securityMode: UInt8) -> SMBRequest {
        var b = RequestBuilder(.sessionSetup, bodyCapacity: 24 + blob.count)
        b.w.u16(25)
        b.w.u8(0)
        b.w.u8(securityMode)
        b.w.u32(0)
        b.w.u32(0)
        b.w.u16(UInt16(SMB2.headerSize + 24))
        b.w.u16(UInt16(blob.count))
        b.w.u64(0)
        b.w.append(blob)
        return b.finish()
    }

    static func logoff() -> SMBRequest {
        var b = RequestBuilder(.logoff, bodyCapacity: 4)
        b.w.u16(4)
        b.w.u16(0)
        return b.finish()
    }

    static func treeConnect(path: String) -> SMBRequest {
        let unc = NTLMClient.utf16LE(path)
        var b = RequestBuilder(.treeConnect, bodyCapacity: 8 + unc.count)
        b.w.u16(9)
        b.w.u16(0)
        b.w.u16(UInt16(SMB2.headerSize + 8))
        b.w.u16(UInt16(unc.count))
        b.w.append(unc)
        return b.finish()
    }

    static func treeDisconnect() -> SMBRequest {
        var b = RequestBuilder(.treeDisconnect, bodyCapacity: 4)
        b.w.u16(4)
        b.w.u16(0)
        return b.finish()
    }

    static func echo() -> SMBRequest {
        var b = RequestBuilder(.echo, bodyCapacity: 4)
        b.w.u16(4)
        b.w.u16(0)
        return b.finish()
    }

    static func cancel() -> SMBRequest {
        var b = RequestBuilder(.cancel, bodyCapacity: 4)
        b.w.u16(4)
        b.w.u16(0)
        return b.finish(creditCharge: 0)
    }

    /// `path` uses backslashes and is relative to the share root ("" opens the root).
    static func create(path: String, access: SMBAccess, attributes: SMBFileAttributes = [],
                       shareAccess: SMBShareAccess = .all, disposition: SMBCreateDisposition,
                       options: SMBCreateOptions, contexts: [UInt8] = []) -> SMBRequest {
        let name = NTLMClient.utf16LE(path)
        var b = RequestBuilder(.create, bodyCapacity: 64 + name.count + contexts.count)
        b.w.u16(57)
        b.w.u8(0)               // SecurityFlags
        b.w.u8(0)               // RequestedOplockLevel: none
        b.w.u32(2)              // ImpersonationLevel: Impersonation
        b.w.u64(0)              // SmbCreateFlags
        b.w.u64(0)              // Reserved
        b.w.u32(access.rawValue)
        b.w.u32(attributes.rawValue)
        b.w.u32(shareAccess.rawValue)
        b.w.u32(disposition.rawValue)
        b.w.u32(options.rawValue)
        b.w.u16(UInt16(SMB2.headerSize + 56))
        b.w.u16(UInt16(name.count))
        let contextOffsetField = b.w.offset
        b.w.u32(0)
        b.w.u32(UInt32(contexts.count))
        if name.isEmpty { b.w.u8(0) } else { b.w.append(name) }
        if !contexts.isEmpty {
            b.w.align(to: 8)
            b.w.set32(UInt32(b.w.offset), at: contextOffsetField)
            b.w.append(contexts)
        }
        return b.finish()
    }

    static func close(_ fileID: SMBFileID, postQueryAttributes: Bool = false) -> SMBRequest {
        var b = RequestBuilder(.close, bodyCapacity: 24)
        b.w.u16(24)
        b.w.u16(postQueryAttributes ? 0x0001 : 0)
        b.w.u32(0)
        b.fileID(fileID)
        return b.finish()
    }

    static func flush(_ fileID: SMBFileID) -> SMBRequest {
        var b = RequestBuilder(.flush, bodyCapacity: 24)
        b.w.u16(24)
        b.w.u16(0)
        b.w.u32(0)
        b.fileID(fileID)
        return b.finish()
    }

    static func read(_ fileID: SMBFileID, offset: UInt64, length: Int) -> SMBRequest {
        var b = RequestBuilder(.read, bodyCapacity: 49)
        b.w.u16(49)
        b.w.u8(0x50)            // Padding: where we'd like the data to start
        b.w.u8(0)
        b.w.u32(UInt32(length))
        b.w.u64(offset)
        b.fileID(fileID)
        b.w.u32(0)              // MinimumCount
        b.w.u32(0)              // Channel
        b.w.u32(0)              // RemainingBytes
        b.w.u16(0)
        b.w.u16(0)
        b.w.u8(0)
        return b.finish(creditCharge: SMB2.creditCharge(forPayload: length))
    }

    /// Builds a WRITE whose payload `fill` writes directly into the frame (no extra copy).
    static func write(_ fileID: SMBFileID, offset: UInt64, length: Int,
                      fill: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows -> SMBRequest {
        var b = RequestBuilder(.write, bodyCapacity: 48 + length)
        b.w.u16(49)
        b.w.u16(UInt16(SMB2.headerSize + 48))
        b.w.u32(UInt32(length))
        b.w.u64(offset)
        b.fileID(fileID)
        b.w.u32(0)              // Channel
        b.w.u32(0)              // RemainingBytes
        b.w.u16(0)
        b.w.u16(0)
        b.w.u32(0)              // Flags
        let dataStart = b.w.bytes.count
        b.w.zeros(length)
        if length > 0 {
            try b.w.bytes.withUnsafeMutableBytes { raw in
                try fill(UnsafeMutableRawBufferPointer(rebasing: raw[dataStart...]))
            }
        }
        return b.finish(creditCharge: SMB2.creditCharge(forPayload: length))
    }

    static func queryDirectory(_ fileID: SMBFileID, infoClass: SMBFileInfoClass, flags: UInt8,
                               pattern: String, outputLength: Int) -> SMBRequest {
        let name = NTLMClient.utf16LE(pattern)
        var b = RequestBuilder(.queryDirectory, bodyCapacity: 32 + name.count)
        b.w.u16(33)
        b.w.u8(infoClass.rawValue)
        b.w.u8(flags)
        b.w.u32(0)
        b.fileID(fileID)
        b.w.u16(UInt16(SMB2.headerSize + 32))
        b.w.u16(UInt16(name.count))
        b.w.u32(UInt32(outputLength))
        if name.isEmpty { b.w.u8(0) } else { b.w.append(name) }
        return b.finish(creditCharge: SMB2.creditCharge(forPayload: outputLength))
    }

    static func changeNotify(_ fileID: SMBFileID, recursive: Bool, filter: UInt32, outputLength: Int) -> SMBRequest {
        var b = RequestBuilder(.changeNotify, bodyCapacity: 32)
        b.w.u16(32)
        b.w.u16(recursive ? 0x0001 : 0)
        b.w.u32(UInt32(outputLength))
        b.fileID(fileID)
        b.w.u32(filter)
        b.w.u32(0)
        return b.finish(creditCharge: SMB2.creditCharge(forPayload: outputLength), timeout: .unlimited)
    }

    static func queryInfo(_ fileID: SMBFileID, type: SMBInfoType, infoClass: UInt8, outputLength: Int,
                          additionalInformation: UInt32 = 0) -> SMBRequest {
        var b = RequestBuilder(.queryInfo, bodyCapacity: 41)
        b.w.u16(41)
        b.w.u8(type.rawValue)
        b.w.u8(infoClass)
        b.w.u32(UInt32(outputLength))
        b.w.u16(0)
        b.w.u16(0)
        b.w.u32(0)
        b.w.u32(additionalInformation)
        b.w.u32(0)
        b.fileID(fileID)
        b.w.u8(0)
        return b.finish(creditCharge: SMB2.creditCharge(forPayload: outputLength))
    }

    static func setInfo(_ fileID: SMBFileID, type: SMBInfoType = .file, infoClass: SMBFileInfoClass,
                        buffer: [UInt8]) -> SMBRequest {
        var b = RequestBuilder(.setInfo, bodyCapacity: 32 + buffer.count)
        b.w.u16(33)
        b.w.u8(type.rawValue)
        b.w.u8(infoClass.rawValue)
        b.w.u32(UInt32(buffer.count))
        b.w.u16(UInt16(SMB2.headerSize + 32))
        b.w.u16(0)
        b.w.u32(0)
        b.fileID(fileID)
        b.w.append(buffer)
        return b.finish(creditCharge: SMB2.creditCharge(forPayload: buffer.count))
    }

    // MARK: Info buffers

    /// FileRenameInformation (SMB2 form). `target` is the full path from the share root.
    static func renameInfo(target: String, replaceIfExists: Bool) -> [UInt8] {
        let name = NTLMClient.utf16LE(target)
        var w = ByteWriter(capacity: 20 + name.count)
        w.u8(replaceIfExists ? 1 : 0)
        w.zeros(7)
        w.u64(0)                 // RootDirectory
        w.u32(UInt32(name.count))
        w.append(name)
        return w.bytes
    }

    /// FileBasicInformation. Zero leaves a timestamp unchanged; empty attributes too.
    static func basicInfo(creation: UInt64 = 0, lastAccess: UInt64 = 0, lastWrite: UInt64 = 0,
                          change: UInt64 = 0, attributes: SMBFileAttributes = []) -> [UInt8] {
        var w = ByteWriter(capacity: 40)
        w.u64(creation)
        w.u64(lastAccess)
        w.u64(lastWrite)
        w.u64(change)
        w.u32(attributes.rawValue)
        w.u32(0)
        return w.bytes
    }

    static func dispositionInfo(deletePending: Bool) -> [UInt8] { [deletePending ? 1 : 0] }

    static func endOfFileInfo(_ size: UInt64) -> [UInt8] {
        var w = ByteWriter(capacity: 8)
        w.u64(size)
        return w.bytes
    }
}

// MARK: - Responses

struct SMB2Header: Sendable {
    var creditCharge: UInt16
    var status: NTStatus
    var command: UInt16
    var credits: UInt16
    var flags: UInt32
    var nextCommand: UInt32
    var messageID: UInt64
    var asyncID: UInt64
    var treeID: UInt32
    var sessionID: UInt64

    static let protocolID: UInt32 = 0x424D_53FE       // 0xFE 'S' 'M' 'B'
    static let transformID: UInt32 = 0x424D_53FD      // 0xFD 'S' 'M' 'B'
    static let compressionID: UInt32 = 0x424D_53FC    // 0xFC 'S' 'M' 'B'

    init(_ r: ByteReader) throws {
        guard r.count >= SMB2.headerSize, try r.u32(0) == Self.protocolID else {
            throw SMBError.malformed("not an SMB2 message")
        }
        creditCharge = try r.u16(6)
        status = NTStatus(try r.u32(8))
        command = try r.u16(12)
        credits = try r.u16(14)
        flags = try r.u32(16)
        nextCommand = try r.u32(20)
        messageID = try r.u64(24)
        if flags & SMB2HeaderFlag.asyncCommand != 0 {
            asyncID = try r.u64(32)
            treeID = 0
        } else {
            asyncID = 0
            treeID = try r.u32(36)
        }
        sessionID = try r.u64(40)
    }

    var isAsync: Bool { flags & SMB2HeaderFlag.asyncCommand != 0 }
    var isSigned: Bool { flags & SMB2HeaderFlag.signed != 0 }
}

/// One response from a (possibly compound, possibly decrypted) frame.
struct SMBMessage: Sendable {
    let reader: ByteReader
    let header: SMB2Header
    /// The frame arrived encrypted (so it carried no signature).
    let wasEncrypted: Bool

    var status: NTStatus { header.status }
    var body: Int { SMB2.headerSize }

    /// The message bytes exactly as received (for the pre-authentication hash).
    var bytes: ArraySlice<UInt8> { reader.bytes[reader.start..<reader.end] }

    /// Throws `.status` for error statuses (warnings such as STATUS_BUFFER_OVERFLOW pass).
    func check() throws {
        if status.isError { throw SMBError.status(status) }
    }

    /// The variable-length output buffer shared by QUERY_DIRECTORY, QUERY_INFO and CHANGE_NOTIFY
    /// responses (StructureSize 9, offset at +2, length at +4).
    func outputBuffer() throws -> ByteReader {
        let offset = Int(try reader.u16(body + 2))
        let length = Int(try reader.u32(body + 4))
        if length == 0 { return ByteReader(reader.bytes, start: reader.start, end: reader.start) }
        return try reader.sub(offset, length)
    }
}

struct NegotiateResponse {
    var securityMode: UInt16
    var dialect: SMBDialect
    var serverGUID: [UInt8]
    var capabilities: UInt32
    var maxTransactSize: Int
    var maxReadSize: Int
    var maxWriteSize: Int
    var securityBlob: [UInt8]
    var cipher: SMBCipher?
    var signingAlgorithm: SMBSigningAlgorithm?

    init(_ m: SMBMessage) throws {
        let r = m.reader
        let o = m.body
        guard try r.u16(o) == 65 else { throw SMBError.malformed("bad NEGOTIATE response size") }
        securityMode = try r.u16(o + 2)
        dialect = SMBDialect(rawValue: try r.u16(o + 4))
        let contextCount = Int(try r.u16(o + 6))
        serverGUID = try r.array(o + 8, 16)
        capabilities = try r.u32(o + 24)
        maxTransactSize = Int(try r.u32(o + 28))
        maxReadSize = Int(try r.u32(o + 32))
        maxWriteSize = Int(try r.u32(o + 36))
        let blobOffset = Int(try r.u16(o + 56))
        let blobLength = Int(try r.u16(o + 58))
        securityBlob = []
        if blobLength > 0 { securityBlob = try r.array(blobOffset, blobLength) }
        cipher = nil
        signingAlgorithm = nil

        if dialect == .smb311, contextCount > 0 {
            var position = Int(try r.u32(o + 60))
            for _ in 0..<contextCount {
                let type = try r.u16(position)
                let length = Int(try r.u16(position + 2))
                let data = position + 8
                switch type {
                case SMB2NegotiateContext.encryption:
                    if length >= 4, try r.u16(data) >= 1 { cipher = SMBCipher(rawValue: try r.u16(data + 2)) }
                case SMB2NegotiateContext.signing:
                    if length >= 4, try r.u16(data) >= 1 {
                        signingAlgorithm = SMBSigningAlgorithm(rawValue: try r.u16(data + 2))
                    }
                default:
                    break
                }
                position = data + length
                position += (8 - position % 8) % 8
            }
        }
    }
}

struct SessionSetupResponse {
    var sessionFlags: UInt16
    var securityBlob: [UInt8]

    init(_ m: SMBMessage) throws {
        let r = m.reader
        let o = m.body
        sessionFlags = try r.u16(o + 2)
        let offset = Int(try r.u16(o + 4))
        let length = Int(try r.u16(o + 6))
        securityBlob = []
        if length > 0 { securityBlob = try r.array(offset, length) }
    }
}

struct TreeConnectResponse {
    var shareType: UInt8
    var shareFlags: UInt32
    var capabilities: UInt32
    var maximalAccess: UInt32

    init(_ m: SMBMessage) throws {
        let r = m.reader
        let o = m.body
        shareType = try r.u8(o + 2)
        shareFlags = try r.u32(o + 4)
        capabilities = try r.u32(o + 8)
        maximalAccess = try r.u32(o + 12)
    }
}

/// Timestamps, sizes and attributes as returned by CREATE and CLOSE (with POSTQUERY_ATTRIB).
struct SMBFileStat: Sendable, Equatable {
    var creationTime: UInt64
    var lastAccessTime: UInt64
    var lastWriteTime: UInt64
    var changeTime: UInt64
    var allocationSize: UInt64
    var endOfFile: UInt64
    var attributes: SMBFileAttributes

    init(_ r: ByteReader, at o: Int) throws {
        creationTime = try r.u64(o)
        lastAccessTime = try r.u64(o + 8)
        lastWriteTime = try r.u64(o + 16)
        changeTime = try r.u64(o + 24)
        allocationSize = try r.u64(o + 32)
        endOfFile = try r.u64(o + 40)
        attributes = SMBFileAttributes(rawValue: try r.u32(o + 48))
    }
}

struct CreateResponse {
    var fileID: SMBFileID
    var createAction: UInt32
    var stat: SMBFileStat

    init(_ m: SMBMessage) throws {
        let r = m.reader
        let o = m.body
        guard try r.u16(o) == 89 else { throw SMBError.malformed("bad CREATE response size") }
        createAction = try r.u32(o + 4)
        stat = try SMBFileStat(r, at: o + 8)
        fileID = SMBFileID(persistent: try r.u64(o + 64), volatile: try r.u64(o + 72))
    }
}

struct CloseResponse {
    var stat: SMBFileStat?

    init(_ m: SMBMessage) throws {
        let r = m.reader
        let o = m.body
        let flags = try r.u16(o + 2)
        stat = nil
        if flags & 0x0001 != 0 { stat = try SMBFileStat(r, at: o + 8) }
    }
}

struct ReadResponse {
    /// Absolute range of the data inside `buffer`.
    var data: Range<Int>
    var buffer: [UInt8]

    init(_ m: SMBMessage) throws {
        let r = m.reader
        let o = m.body
        let dataOffset = Int(try r.u8(o + 2))
        let dataLength = Int(try r.u32(o + 4))
        try r.check(dataOffset, dataLength)
        data = (r.start + dataOffset)..<(r.start + dataOffset + dataLength)
        buffer = r.bytes
    }
}

struct WriteResponse {
    var count: Int

    init(_ m: SMBMessage) throws {
        count = Int(try m.reader.u32(m.body + 4))
    }
}

/// One FileIdFullDirectoryInformation entry.
struct DirectoryEntry: Sendable {
    var name: String
    var fileID: UInt64
    var stat: SMBFileStat
}

enum DirectoryParser {
    static func entries(_ r: ByteReader) throws -> [DirectoryEntry] {
        var out: [DirectoryEntry] = []
        guard r.count > 0 else { return out }
        var position = 0
        while true {
            let next = Int(try r.u32(position))
            let stat = try SMBFileStat(r, at: position + 8)
            let nameLength = Int(try r.u32(position + 60))
            let fileID = try r.u64(position + 72)
            let name = try r.utf16(position + 80, byteCount: nameLength)
            out.append(DirectoryEntry(name: name, fileID: fileID, stat: stat))
            if next == 0 { break }
            guard next >= 80 else { throw SMBError.malformed("bad directory entry chain") }
            position += next
        }
        return out
    }
}

public enum SMBChangeAction: UInt32, Sendable {
    case added = 1
    case removed = 2
    case modified = 3
    case renamedOldName = 4
    case renamedNewName = 5
    case addedStream = 6
    case removedStream = 7
    case modifiedStream = 8
}

enum NotifyParser {
    static func entries(_ r: ByteReader) throws -> [(SMBChangeAction?, String)] {
        var out: [(SMBChangeAction?, String)] = []
        guard r.count > 0 else { return out }
        var position = 0
        while true {
            let next = Int(try r.u32(position))
            let action = SMBChangeAction(rawValue: try r.u32(position + 4))
            let nameLength = Int(try r.u32(position + 8))
            let name = try r.utf16(position + 12, byteCount: nameLength)
            out.append((action, name))
            if next == 0 { break }
            guard next >= 12 else { throw SMBError.malformed("bad notify entry chain") }
            position += next
        }
        return out
    }
}
