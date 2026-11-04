import Foundation

// Wire formats for symbolic links, extended attributes and named streams.

// MARK: - Symbolic links

/// Symbolic links on SMB come in two shapes:
///
/// - **Reparse points** (MS-FSCC 2.1.2.4): what Windows creates, and what NTFS-backed NAS
///   firmware reports. Read and written with FSCTL_GET/SET_REPARSE_POINT. Creating one needs a
///   privilege most accounts don't have, and Samba doesn't support it.
/// - **Minshall-French symlinks** ("XSym" files): a 1067-byte regular file holding the target.
///   This is what macOS smbfs and Linux cifs (`mfsymlinks`) create when the server can't store a
///   real link, so a Mac mounting the same share sees the same link.
enum SymlinkCodec {
    static let xsymMagic = Array("XSym\n".utf8)
    /// Every XSym file is exactly this long.
    static let xsymFileSize = 1067
    static let xsymMaxTargetLength = 1024
    private static let lengthOffset = 5
    private static let md5Offset = 10
    private static let targetOffset = 43

    /// Encodes `target` as an XSym file.
    static func xsym(target: String) throws -> [UInt8] {
        let bytes = Array(target.utf8)
        guard !bytes.isEmpty, bytes.count <= xsymMaxTargetLength else {
            throw SMBError.invalidArgument("A symbolic link target must be 1–\(xsymMaxTargetLength) bytes long.")
        }
        var out = xsymMagic
        let length = String(bytes.count)
        out += Array((String(repeating: "0", count: 4 - length.count) + length + "\n").utf8)
        out += Array(hex(SMBCrypto.md5(bytes)).utf8) + [0x0A]
        out += bytes
        if out.count < xsymFileSize { out.append(0x0A) }
        out += [UInt8](repeating: 0x20, count: xsymFileSize - out.count)
        return out
    }

    /// The target stored in an XSym file, or nil when `data` isn't one.
    static func parseXSym<C: Collection>(_ data: C) -> String? where C.Element == UInt8 {
        let bytes = Array(data)
        guard bytes.count == xsymFileSize, bytes.starts(with: xsymMagic), bytes[md5Offset - 1] == 0x0A,
              bytes[targetOffset - 1] == 0x0A,
              let lengthText = String(bytes: bytes[lengthOffset..<(lengthOffset + 4)], encoding: .ascii),
              let length = Int(lengthText), length > 0, length <= xsymMaxTargetLength,
              let md5 = String(bytes: bytes[md5Offset..<(md5Offset + 32)], encoding: .ascii) else { return nil }
        let target = Array(bytes[targetOffset..<(targetOffset + length)])
        guard md5.lowercased() == hex(SMBCrypto.md5(target)) else { return nil }
        return String(decoding: target, as: UTF8.self)
    }

    /// REPARSE_DATA_BUFFER for a relative NTFS symbolic link.
    static func reparseData(relativeTarget target: String) -> [UInt8] {
        let name = NTLMClient.utf16LE(target.replacingOccurrences(of: "/", with: "\\"))
        var body = ByteWriter(capacity: 12 + 2 * name.count)
        body.u16(0)                          // SubstituteNameOffset
        body.u16(UInt16(name.count))         // SubstituteNameLength
        body.u16(UInt16(name.count))         // PrintNameOffset
        body.u16(UInt16(name.count))         // PrintNameLength
        body.u32(1)                          // Flags: SYMLINK_FLAG_RELATIVE
        body.append(name)
        body.append(name)
        var w = ByteWriter(capacity: 8 + body.bytes.count)
        w.u32(SMBReparseTag.symlink)
        w.u16(UInt16(body.bytes.count))
        w.u16(0)
        w.append(body.bytes)
        return w.bytes
    }

    /// `LNK` in NFS_SPECFILE_LNK.
    private static let nfsSymlinkType: UInt64 = 0x0000_0000_014B_4E4C

    /// The target of a symbolic link reparse point (NTFS or NFS style), "/"-separated, or nil
    /// for other kinds of reparse point.
    static func parseReparse(_ r: ByteReader) throws -> String? {
        let tag = try r.u32(0)
        let dataLength = Int(try r.u16(4))
        let data = try r.sub(8, min(dataLength, r.count - 8))
        switch tag {
        case SMBReparseTag.symlink:
            let substituteOffset = Int(try data.u16(0))
            let substituteLength = Int(try data.u16(2))
            let printOffset = Int(try data.u16(4))
            let printLength = Int(try data.u16(6))
            let printName = try data.utf16(12 + printOffset, byteCount: printLength)
            var target = printName
            if target.isEmpty {
                target = try data.utf16(12 + substituteOffset, byteCount: substituteLength)
                if target.hasPrefix("\\??\\") { target.removeFirst(4) }
            }
            guard !target.isEmpty else { return nil }
            // Absolute Windows targets ("C:\…") mean nothing on a Mac, but they're still links.
            return target.replacingOccurrences(of: "\\", with: "/")
        case SMBReparseTag.nfs:
            guard try data.u64(0) == nfsSymlinkType else { return nil }
            let target = try data.utf16(8, byteCount: data.count - 8)
            return target.isEmpty ? nil : target
        default:
            return nil
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Extended attributes (SMB EAs)

/// FILE_FULL_EA_INFORMATION lists (MS-FSCC 2.4.15), plus the name mapping that lets macOS
/// xattr names live in EAs.
///
/// EA names must be ASCII and can't contain `"*+,/:;<=>?[\]|` (Samba rejects them with
/// STATUS_INVALID_EA_NAME), but macOS names such as `com.apple.metadata:_kMDItemUserTags` use a
/// colon. Those characters, `%` and anything outside printable ASCII are stored as `%XX` UTF-8
/// escapes, so `com.apple.metadata%3A_kMDItemUserTags` reads back as the original name.
enum EACodec {
    static let maxNameLength = 255
    static let maxValueLength = Int(UInt16.max)
    private static let reserved = Set("\"*+,/:;<=>?[\\]|%".utf8)

    static func encodeName(_ name: String) -> String {
        var out = ""
        for byte in name.utf8 {
            if byte > 0x20, byte < 0x7F, !reserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func decodeName(_ name: String) -> String {
        guard name.contains("%") else { return name }
        var bytes: [UInt8] = []
        let units = Array(name.utf8)
        var i = 0
        while i < units.count {
            if units[i] == UInt8(ascii: "%"), i + 2 < units.count,
               let high = hexValue(units[i + 1]), let low = hexValue(units[i + 2]) {
                let value = high << 4 | low
                bytes.append(value)
                i += 3
            } else {
                bytes.append(units[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Encodes entries; an empty value deletes that EA on the server.
    static func encode(_ entries: [(name: String, value: [UInt8])]) throws -> [UInt8] {
        var w = ByteWriter(capacity: 256)
        for (index, entry) in entries.enumerated() {
            let name = Array(encodeName(entry.name).utf8)
            guard !name.isEmpty, name.count <= maxNameLength else {
                throw SMBError.invalidArgument("The extended attribute name \(entry.name) is too long for the server.")
            }
            guard entry.value.count <= maxValueLength else {
                throw SMBError.invalidArgument("The extended attribute \(entry.name) is too large for the server.")
            }
            let start = w.offset
            w.u32(0)
            w.u8(0)
            w.u8(UInt8(name.count))
            w.u16(UInt16(entry.value.count))
            w.append(name)
            w.u8(0)
            w.append(entry.value)
            if index < entries.count - 1 {
                w.align(to: 4)
                w.set32(UInt32(w.offset - start), at: start)
            }
        }
        return w.bytes
    }

    static func parse(_ r: ByteReader) throws -> [(name: String, value: [UInt8])] {
        var out: [(name: String, value: [UInt8])] = []
        guard r.count > 0 else { return out }
        var position = 0
        while true {
            let next = Int(try r.u32(position))
            let nameLength = Int(try r.u8(position + 5))
            let valueLength = Int(try r.u16(position + 6))
            let name = String(decoding: try r.slice(position + 8, nameLength), as: UTF8.self)
            let value = try r.array(position + 8 + nameLength + 1, valueLength)
            out.append((decodeName(name), value))
            if next == 0 { break }
            guard next >= 8 else { throw SMBError.malformed("bad EA entry chain") }
            position += next
        }
        return out
    }
}

// MARK: - Named streams

/// Extended attributes stored as named streams, the way macOS smbfs does it (and Samba's
/// vfs_fruit expects): xattr `X` is the stream `file:X`, with the characters NTFS forbids mapped
/// into the Services for Macintosh private-use range (`:` → U+F022…). Two names are special:
/// `com.apple.FinderInfo` lives inside the `AFP_AfpInfo` stream and `com.apple.ResourceFork`
/// is the `AFP_Resource` stream.
enum StreamCodec {
    static let finderInfoName = "com.apple.FinderInfo"
    static let resourceForkName = "com.apple.ResourceFork"
    static let afpInfoStream = "AFP_AfpInfo"
    static let afpResourceStream = "AFP_Resource"
    static let afpInfoSize = 60
    static let finderInfoSize = 32

    private static let sfm: [UInt8: UInt16] = [
        UInt8(ascii: "\""): 0xF020, UInt8(ascii: "*"): 0xF021, UInt8(ascii: ":"): 0xF022,
        UInt8(ascii: "<"): 0xF023, UInt8(ascii: ">"): 0xF024, UInt8(ascii: "?"): 0xF025,
        UInt8(ascii: "/"): 0xF026, UInt8(ascii: "\\"): 0xF026, UInt8(ascii: "|"): 0xF027,
    ]

    /// Maps an xattr name to the stream name that holds it.
    static func streamName(forAttribute name: String) -> String {
        switch name {
        case finderInfoName: return afpInfoStream
        case resourceForkName: return afpResourceStream
        default: break
        }
        var scalars = Array(name.unicodeScalars)
        for (i, scalar) in scalars.enumerated() where scalar.value < 0x80 {
            let byte = UInt8(scalar.value)
            if byte > 0, byte < 0x20 {
                scalars[i] = Unicode.Scalar(UInt32(0xF000) + UInt32(byte))!
            } else if let mapped = sfm[byte] {
                scalars[i] = Unicode.Scalar(UInt32(mapped))!
            }
        }
        // Windows drops a trailing space or period.
        if let last = scalars.last {
            if last == " " { scalars[scalars.count - 1] = Unicode.Scalar(UInt32(0xF028))! }
            if last == "." { scalars[scalars.count - 1] = Unicode.Scalar(UInt32(0xF029))! }
        }
        var out = ""
        out.unicodeScalars.append(contentsOf: scalars)
        return out
    }

    /// The inverse of `streamName(forAttribute:)`.
    static func attributeName(forStream name: String) -> String {
        switch name {
        case afpInfoStream: return finderInfoName
        case afpResourceStream: return resourceForkName
        default: break
        }
        var out = ""
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0xF001...0xF01F: out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xF000)!)
            case 0xF020: out += "\""
            case 0xF021: out += "*"
            case 0xF022: out += ":"
            case 0xF023: out += "<"
            case 0xF024: out += ">"
            case 0xF025: out += "?"
            case 0xF026: out += "/"
            case 0xF027: out += "|"
            case 0xF028: out += " "
            case 0xF029: out += "."
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Named data streams in a FileStreamInformation buffer, without the unnamed `::$DATA`.
    static func parseStreams(_ r: ByteReader) throws -> [(name: String, size: Int64)] {
        var out: [(name: String, size: Int64)] = []
        guard r.count > 0 else { return out }
        var position = 0
        while true {
            let next = Int(try r.u32(position))
            let nameLength = Int(try r.u32(position + 4))
            let size = Int64(bitPattern: try r.u64(position + 8))
            let raw = try r.utf16(position + 24, byteCount: nameLength)
            // ":name:$DATA"
            var name = Substring(raw)
            if name.hasPrefix(":") { name = name.dropFirst() }
            if let colon = name.lastIndex(of: ":") {
                let type = name[name.index(after: colon)...]
                name = name[..<colon]
                if type.caseInsensitiveCompare("$DATA") == .orderedSame, !name.isEmpty {
                    out.append((String(name), size))
                }
            }
            if next == 0 { break }
            guard next >= 24 else { throw SMBError.malformed("bad stream entry chain") }
            position += next
        }
        return out
    }

    /// Wraps 32 bytes of FinderInfo in an AfpInfo structure (MS-SMB 2.2.1.2.2 / Samba's vfs_fruit).
    static func afpInfo(finderInfo: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x41, 0x46, 0x50, 0x00]      // Signature "AFP\0"
        out += [0x00, 0x00, 0x01, 0x00]                  // Version 0x00010000 (little-endian)
        out += [0x00, 0x00, 0x00, 0x00]                  // Reserved
        out += [0x80, 0x00, 0x00, 0x00]                  // BackupTime: never
        var info = Array(finderInfo.prefix(finderInfoSize))
        info += [UInt8](repeating: 0, count: finderInfoSize - info.count)
        out += info
        out += [UInt8](repeating: 0, count: afpInfoSize - out.count) // ProDOS info, reserved
        return out
    }

    /// The FinderInfo inside an AfpInfo stream.
    static func finderInfo(fromAfpInfo data: [UInt8]) -> [UInt8]? {
        guard data.count >= 16 + finderInfoSize, data.starts(with: [0x41, 0x46, 0x50, 0x00]) else { return nil }
        return Array(data[16..<(16 + finderInfoSize)])
    }
}
