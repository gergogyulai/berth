import Foundation

/// Little-endian encoder for SMB2 structures.
///
/// `origin` is the index in `bytes` that SMB2 offsets are measured from (the first byte of the
/// SMB2 header). Outgoing frames reserve four bytes in front of the header for the Direct TCP
/// length prefix, so a whole request is built in one contiguous buffer and handed to the socket
/// without another copy.
struct ByteWriter {
    var bytes: [UInt8]
    let origin: Int

    init(origin: Int = 0, capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(origin + capacity)
        bytes.append(contentsOf: repeatElement(0, count: origin))
        self.origin = origin
    }

    /// Current write position relative to `origin`.
    var offset: Int { bytes.count - origin }

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value &>> 8))
    }

    mutating func u32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value &>> 8))
        bytes.append(UInt8(truncatingIfNeeded: value &>> 16))
        bytes.append(UInt8(truncatingIfNeeded: value &>> 24))
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value))
        u32(UInt32(truncatingIfNeeded: value &>> 32))
    }

    mutating func append<C: Collection>(_ data: C) where C.Element == UInt8 {
        bytes.append(contentsOf: data)
    }

    mutating func zeros(_ count: Int) {
        if count > 0 { bytes.append(contentsOf: repeatElement(0, count: count)) }
    }

    /// Pads with zeros until `offset` is a multiple of `alignment`.
    mutating func align(to alignment: Int) {
        let remainder = offset % alignment
        if remainder != 0 { zeros(alignment - remainder) }
    }

    /// UTF-16LE without a terminator.
    mutating func utf16(_ string: String) {
        for unit in string.utf16 { u16(unit) }
    }

    mutating func set16(_ value: UInt16, at offset: Int) { bytes.storeLE(value, at: origin + offset) }
    mutating func set32(_ value: UInt32, at offset: Int) { bytes.storeLE(value, at: origin + offset) }
    mutating func set64(_ value: UInt64, at offset: Int) { bytes.storeLE(value, at: origin + offset) }
}

extension Array where Element == UInt8 {
    /// Unchecked little-endian load. Callers validate bounds first (see `ByteReader`).
    @inline(__always)
    func loadLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    @inline(__always)
    mutating func storeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count, "store out of bounds")
        withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self) }
    }
}

/// Bounds-checked little-endian decoder over a region of a received frame.
///
/// Offsets are relative to `start`, which for SMB2 messages is the first byte of the header —
/// the same base the protocol uses for its offset fields.
struct ByteReader {
    let bytes: [UInt8]
    let start: Int
    let end: Int

    init(_ bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.start = start
        self.end = min(end ?? bytes.count, bytes.count)
    }

    var count: Int { end - start }

    func contains(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && start + offset <= end && length <= end - (start + offset)
    }

    func check(_ offset: Int, _ length: Int) throws {
        guard contains(offset, length) else {
            throw SMBError.malformed("Field at \(offset)+\(length) is outside the \(count)-byte message")
        }
    }

    func u8(_ offset: Int) throws -> UInt8 {
        try check(offset, 1)
        return bytes[start + offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        return bytes.loadLE(UInt16.self, at: start + offset)
    }

    func u32(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return bytes.loadLE(UInt32.self, at: start + offset)
    }

    func u64(_ offset: Int) throws -> UInt64 {
        try check(offset, 8)
        return bytes.loadLE(UInt64.self, at: start + offset)
    }

    func slice(_ offset: Int, _ length: Int) throws -> ArraySlice<UInt8> {
        try check(offset, length)
        return bytes[(start + offset)..<(start + offset + length)]
    }

    func array(_ offset: Int, _ length: Int) throws -> [UInt8] {
        Array(try slice(offset, length))
    }

    /// A reader over a sub-region; offsets in the result are relative to `offset`.
    func sub(_ offset: Int, _ length: Int) throws -> ByteReader {
        try check(offset, length)
        return ByteReader(bytes, start: start + offset, end: start + offset + length)
    }

    func utf16(_ offset: Int, byteCount: Int) throws -> String {
        try check(offset, byteCount)
        let unitCount = byteCount / 2
        var units = [UInt16]()
        units.reserveCapacity(unitCount)
        var position = start + offset
        for _ in 0..<unitCount {
            units.append(UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8)
            position += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Windows FILETIME: 100 ns intervals since 1601-01-01 UTC.
public enum FileTime {
    static let unixEpochOffset: Int64 = 116_444_736_000_000_000

    public static func date(_ value: UInt64) -> Date? {
        guard value != 0, value != UInt64.max else { return nil }
        let ticks = Int64(bitPattern: value) - unixEpochOffset
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000)
    }

    public static func value(_ date: Date) -> UInt64 {
        let ticks = (date.timeIntervalSince1970 * 10_000_000).rounded() + Double(unixEpochOffset)
        guard ticks > 0 else { return 0 }
        guard ticks < Double(Int64.max) else { return UInt64(Int64.max) }
        return UInt64(ticks)
    }
}

extension String {
    /// SMB servers store names precomposed (NFC); macOS hands out decomposed names in places.
    var smbNormalized: String { precomposedStringWithCanonicalMapping }
}
