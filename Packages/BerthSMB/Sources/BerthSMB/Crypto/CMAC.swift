import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// AES-128-CMAC (RFC 4493), the SMB 3.0 / 3.0.2 signing algorithm (and the 3.1.1 fallback
/// when a server doesn't offer AES-GMAC).
///
/// CMAC is CBC-MAC with a tweaked last block, so the bulk of the message runs through a single
/// AES-CBC encryptor (hardware accelerated through CommonCrypto on Apple platforms) and only
/// the final block is handled here.
struct AESCMAC {
    let key: [UInt8]
    private let k1: [UInt8]
    private let k2: [UInt8]

    init(key: [UInt8]) {
        precondition(key.count == 16, "AES-128-CMAC needs a 16-byte key")
        self.key = key
        let encryptor = AESCBCEncryptor(key: key)
        let l = encryptor.encryptChained([UInt8](repeating: 0, count: 16))
        k1 = AESCMAC.double(l)
        k2 = AESCMAC.double(k1)
    }

    static func double(_ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var carry: UInt8 = 0
        for i in stride(from: 15, through: 0, by: -1) {
            out[i] = (block[i] << 1) | carry
            carry = block[i] >> 7
        }
        if block[0] & 0x80 != 0 { out[15] ^= 0x87 }
        return out
    }

    func mac(_ message: UnsafeRawBufferPointer) -> [UInt8] {
        let length = message.count
        let blockCount = max(1, (length + 15) / 16)
        let lastIsComplete = length > 0 && length % 16 == 0
        let headLength = (blockCount - 1) * 16

        var last = [UInt8](repeating: 0, count: 16)
        if lastIsComplete {
            for i in 0..<16 { last[i] = message[headLength + i] ^ k1[i] }
        } else {
            let remainder = length - headLength
            for i in 0..<remainder { last[i] = message[headLength + i] }
            last[remainder] = 0x80
            for i in 0..<16 { last[i] ^= k2[i] }
        }

        let encryptor = AESCBCEncryptor(key: key)
        if headLength > 0 {
            encryptor.update(UnsafeRawBufferPointer(rebasing: message[0..<headLength]))
        }
        return encryptor.encryptChained(last)
    }

    func mac(_ message: [UInt8]) -> [UInt8] {
        message.withUnsafeBytes { mac($0) }
    }
}

#if canImport(CommonCrypto)

/// AES-128-CBC with a zero IV whose chaining value (the last ciphertext block) is the running
/// CBC-MAC. Not thread-safe; create one per MAC computation.
final class AESCBCEncryptor {
    private var cryptor: CCCryptorRef?
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    private(set) var chain = [UInt8](repeating: 0, count: 16)

    init(key: [UInt8]) {
        let iv = [UInt8](repeating: 0, count: 16)
        let status = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                                     key, key.count, iv, &cryptor)
        precondition(status == CCCryptorStatus(kCCSuccess), "CCCryptorCreate failed (\(status))")
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    /// Feeds whole blocks (`data.count` must be a multiple of 16).
    func update(_ data: UnsafeRawBufferPointer) {
        guard let base = data.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let length = min(scratch.count, data.count - offset)
            var moved = 0
            scratch.withUnsafeMutableBytes { out in
                _ = CCCryptorUpdate(cryptor, base + offset, length, out.baseAddress, length, &moved)
            }
            if moved >= 16 {
                for i in 0..<16 { chain[i] = scratch[moved - 16 + i] }
            }
            offset += length
        }
    }

    /// Encrypts one more block in the chain and returns it.
    func encryptChained(_ block: [UInt8]) -> [UInt8] {
        block.withUnsafeBytes { update($0) }
        return chain
    }
}

#else

/// Portable fallback (used on Linux, where CommonCrypto doesn't exist).
final class AESCBCEncryptor {
    private let aes: SoftAES128
    private(set) var chain = [UInt8](repeating: 0, count: 16)

    init(key: [UInt8]) { aes = SoftAES128(key: key) }

    func update(_ data: UnsafeRawBufferPointer) {
        var offset = 0
        while offset + 16 <= data.count {
            for i in 0..<16 { chain[i] ^= data[offset + i] }
            aes.encrypt(&chain)
            offset += 16
        }
    }

    func encryptChained(_ block: [UInt8]) -> [UInt8] {
        block.withUnsafeBytes { update($0) }
        return chain
    }
}

/// Straightforward AES-128 encryption (FIPS-197). Slow but only used for CMAC off Apple platforms.
struct SoftAES128 {
    private var roundKeys = [UInt32](repeating: 0, count: 44)

    private static let sbox: [UInt8] = [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
    ]

    private static let rcon: [UInt32] = [
        0x0100_0000, 0x0200_0000, 0x0400_0000, 0x0800_0000, 0x1000_0000,
        0x2000_0000, 0x4000_0000, 0x8000_0000, 0x1B00_0000, 0x3600_0000,
    ]

    init(key: [UInt8]) {
        precondition(key.count == 16)
        for i in 0..<4 {
            roundKeys[i] = UInt32(key[4 * i]) << 24 | UInt32(key[4 * i + 1]) << 16
                | UInt32(key[4 * i + 2]) << 8 | UInt32(key[4 * i + 3])
        }
        for i in 4..<44 {
            var temp = roundKeys[i - 1]
            if i % 4 == 0 {
                temp = (temp << 8) | (temp >> 24)
                temp = UInt32(Self.sbox[Int(temp >> 24)]) << 24 | UInt32(Self.sbox[Int((temp >> 16) & 0xFF)]) << 16
                    | UInt32(Self.sbox[Int((temp >> 8) & 0xFF)]) << 8 | UInt32(Self.sbox[Int(temp & 0xFF)])
                temp ^= Self.rcon[i / 4 - 1]
            }
            roundKeys[i] = roundKeys[i - 4] ^ temp
        }
    }

    private func addRoundKey(_ state: inout [UInt8], _ round: Int) {
        for c in 0..<4 {
            let word = roundKeys[round * 4 + c]
            state[4 * c] ^= UInt8(truncatingIfNeeded: word >> 24)
            state[4 * c + 1] ^= UInt8(truncatingIfNeeded: word >> 16)
            state[4 * c + 2] ^= UInt8(truncatingIfNeeded: word >> 8)
            state[4 * c + 3] ^= UInt8(truncatingIfNeeded: word)
        }
    }

    private static func xtime(_ x: UInt8) -> UInt8 {
        (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)
    }

    func encrypt(_ state: inout [UInt8]) {
        addRoundKey(&state, 0)
        for round in 1...10 {
            for i in 0..<16 { state[i] = Self.sbox[Int(state[i])] }
            var shifted = state
            for r in 1..<4 {
                for c in 0..<4 { shifted[r + 4 * c] = state[r + 4 * ((c + r) % 4)] }
            }
            state = shifted
            if round != 10 {
                for c in 0..<4 {
                    let a0 = state[4 * c], a1 = state[4 * c + 1], a2 = state[4 * c + 2], a3 = state[4 * c + 3]
                    state[4 * c] = Self.xtime(a0) ^ (Self.xtime(a1) ^ a1) ^ a2 ^ a3
                    state[4 * c + 1] = a0 ^ Self.xtime(a1) ^ (Self.xtime(a2) ^ a2) ^ a3
                    state[4 * c + 2] = a0 ^ a1 ^ Self.xtime(a2) ^ (Self.xtime(a3) ^ a3)
                    state[4 * c + 3] = (Self.xtime(a0) ^ a0) ^ a1 ^ a2 ^ Self.xtime(a3)
                }
            }
            addRoundKey(&state, round)
        }
    }
}

#endif
