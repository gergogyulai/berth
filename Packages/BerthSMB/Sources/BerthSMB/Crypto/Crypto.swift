import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Thin wrappers over CryptoKit with the shapes the protocol code needs.
enum SMBCrypto {
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count { out[i] = UInt8.random(in: .min ... .max, using: &generator) }
        return out
    }

    // MARK: Hashes

    /// SHA-512(previous || message): one step of the SMB 3.1.1 pre-authentication integrity hash.
    static func sha512(_ previous: [UInt8], _ message: some DataProtocol) -> [UInt8] {
        var hasher = SHA512()
        hasher.update(data: previous)
        hasher.update(data: message)
        return Array(hasher.finalize())
    }

    static func md5(_ data: some DataProtocol) -> [UInt8] {
        Array(Insecure.MD5.hash(data: data))
    }

    static func hmacMD5(key: [UInt8], _ data: some DataProtocol) -> [UInt8] {
        var mac = HMAC<Insecure.MD5>(key: SymmetricKey(data: key))
        mac.update(data: data)
        return Array(mac.finalize())
    }

    static func hmacSHA256(key: [UInt8], _ data: some DataProtocol) -> [UInt8] {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
        mac.update(data: data)
        return Array(mac.finalize())
    }

    /// SP800-108 counter-mode KDF with HMAC-SHA256, as used by SMB 3.x (MS-SMB2 3.1.4.2).
    /// `label` and `context` already include their trailing NUL where the spec says so.
    static func kdf(key: [UInt8], label: [UInt8], context: [UInt8], bits: Int) -> [UInt8] {
        var input: [UInt8] = [0, 0, 0, 1]
        input.append(contentsOf: label)
        input.append(0)
        input.append(contentsOf: context)
        input.append(UInt8(truncatingIfNeeded: bits >> 24))
        input.append(UInt8(truncatingIfNeeded: bits >> 16))
        input.append(UInt8(truncatingIfNeeded: bits >> 8))
        input.append(UInt8(truncatingIfNeeded: bits))
        return Array(hmacSHA256(key: key, input).prefix(bits / 8))
    }

    // MARK: AES-GCM

    static func gcmSeal(key: [UInt8], nonce: [UInt8], plaintext: some DataProtocol,
                        aad: some DataProtocol) throws -> (ciphertext: Data, tag: Data) {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                   nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return (box.ciphertext, box.tag)
    }

    static func gcmOpen(key: [UInt8], nonce: [UInt8], ciphertext: some DataProtocol, tag: some DataProtocol,
                        aad: some DataProtocol) throws -> Data {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    /// AES-GMAC: GCM over an empty plaintext with the message as additional data.
    static func gmac(key: [UInt8], nonce: [UInt8], message: some DataProtocol) throws -> [UInt8] {
        let empty = [UInt8]()
        let box = try AES.GCM.seal(empty, using: SymmetricKey(data: key),
                                   nonce: AES.GCM.Nonce(data: nonce), authenticating: message)
        return Array(box.tag)
    }
}

extension Array where Element == UInt8 {
    init(ascii string: String, nulTerminated: Bool) {
        self = Array(string.utf8)
        if nulTerminated { append(0) }
    }
}
