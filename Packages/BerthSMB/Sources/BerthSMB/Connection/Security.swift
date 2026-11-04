import Foundation

/// Signing and sealing state for the session running on a connection.
struct SessionSecurity: Sendable {
    var sessionID: UInt64
    var dialect: SMBDialect
    var signingAlgorithm: SMBSigningAlgorithm
    var signingKey: [UInt8]
    var cmac: AESCMAC?
    var cipher: SMBCipher?
    var encryptionKey: [UInt8]?
    var decryptionKey: [UInt8]?
    /// Sign every request (server requires it, or the client asked for it).
    var signRequests: Bool
    /// Encrypt every request (session or share requires it, or the client asked for it).
    var encryptRequests: Bool

    var canEncrypt: Bool { cipher != nil && encryptionKey != nil && decryptionKey != nil }

    /// Derives the 3.x keys (MS-SMB2 3.2.5.3.1). `preauthHash` is only used for 3.1.1.
    static func derive(sessionKey: [UInt8], sessionID: UInt64, dialect: SMBDialect,
                       signingAlgorithm: SMBSigningAlgorithm, cipher: SMBCipher?, preauthHash: [UInt8]) -> SessionSecurity {
        // Session keys shorter than 16 bytes are zero-padded; longer ones truncated for signing.
        var key = sessionKey
        if key.count < 16 { key += [UInt8](repeating: 0, count: 16 - key.count) }
        let key16 = Array(key.prefix(16))

        var signingKey: [UInt8]
        var encryptionKey: [UInt8]?
        var decryptionKey: [UInt8]?
        if dialect == .smb311 {
            signingKey = SMBCrypto.kdf(key: key16, label: Array(ascii: "SMBSigningKey", nulTerminated: true),
                                       context: preauthHash, bits: 128)
            if let cipher {
                let bits = cipher.keyBits
                encryptionKey = SMBCrypto.kdf(key: key16, label: Array(ascii: "SMBC2SCipherKey", nulTerminated: true),
                                              context: preauthHash, bits: bits)
                decryptionKey = SMBCrypto.kdf(key: key16, label: Array(ascii: "SMBS2CCipherKey", nulTerminated: true),
                                              context: preauthHash, bits: bits)
            }
        } else if dialect.isSMB3 {
            signingKey = SMBCrypto.kdf(key: key16, label: Array(ascii: "SMB2AESCMAC", nulTerminated: true),
                                       context: Array(ascii: "SmbSign", nulTerminated: true), bits: 128)
            // 3.0/3.0.2 encryption is AES-128-CCM only, which this client doesn't implement.
        } else {
            signingKey = key16
        }
        return SessionSecurity(
            sessionID: sessionID, dialect: dialect, signingAlgorithm: signingAlgorithm, signingKey: signingKey,
            cmac: signingAlgorithm == .aesCMAC ? AESCMAC(key: signingKey) : nil,
            cipher: (encryptionKey != nil) ? cipher : nil,
            encryptionKey: encryptionKey, decryptionKey: decryptionKey,
            signRequests: false, encryptRequests: false)
    }

    /// Computes the signature of one SMB2 message whose signature field is already zeroed and
    /// whose SIGNED flag is set.
    func signature(of message: UnsafeRawBufferPointer) throws -> [UInt8] {
        switch signingAlgorithm {
        case .hmacSHA256:
            return Array(SMBCrypto.hmacSHA256(key: signingKey, message).prefix(16))
        case .aesCMAC:
            let mac = cmac ?? AESCMAC(key: signingKey)
            return mac.mac(message)
        case .aesGMAC:
            // Nonce: MessageId, then a 32-bit field with bit 0 = server-to-client and
            // bit 1 = CANCEL request (MS-SMB2 3.1.4.1).
            var nonce = [UInt8](repeating: 0, count: 12)
            for i in 0..<8 { nonce[i] = message[24 + i] }
            let flags = UInt32(message[16]) | UInt32(message[17]) << 8 | UInt32(message[18]) << 16 | UInt32(message[19]) << 24
            let command = UInt16(message[12]) | UInt16(message[13]) << 8
            var role: UInt8 = 0
            if flags & SMB2HeaderFlag.serverToRedirector != 0 { role |= 0x01 }
            if command == SMB2Command.cancel.rawValue { role |= 0x02 }
            nonce[8] = role
            return try SMBCrypto.gmac(key: signingKey, nonce: nonce, message: message)
        }
    }

    /// Signs `buffer[range]` in place.
    func sign(_ buffer: inout [UInt8], range: Range<Int>) throws {
        try buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress! + range.lowerBound
            // Set SMB2_FLAGS_SIGNED and clear the signature field.
            base.storeBytes(of: base.loadUnaligned(fromByteOffset: 16, as: UInt32.self) | SMB2HeaderFlag.signed.littleEndian,
                            toByteOffset: 16, as: UInt32.self)
            for i in 48..<64 { base.storeBytes(of: 0, toByteOffset: i, as: UInt8.self) }
            let signature = try self.signature(of: UnsafeRawBufferPointer(start: base, count: range.count))
            for i in 0..<16 { base.storeBytes(of: signature[i], toByteOffset: 48 + i, as: UInt8.self) }
        }
    }

    /// Verifies `buffer[range]` in place (the signature field is zeroed in the process).
    func verify(_ buffer: inout [UInt8], range: Range<Int>) throws -> Bool {
        try buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress! + range.lowerBound
            var received = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 {
                received[i] = base.load(fromByteOffset: 48 + i, as: UInt8.self)
                base.storeBytes(of: 0, toByteOffset: 48 + i, as: UInt8.self)
            }
            let expected = try self.signature(of: UnsafeRawBufferPointer(start: base, count: range.count))
            var difference: UInt8 = 0
            for i in 0..<16 { difference |= expected[i] ^ received[i] }
            return difference == 0
        }
    }

    // MARK: Encryption (SMB2 TRANSFORM_HEADER, AES-GCM)

    static let transformHeaderSize = 52

    /// Encrypts `plaintext` (one or more SMB2 messages) into a complete wire frame, Direct TCP
    /// prefix included.
    func seal(_ plaintext: UnsafeRawBufferPointer, nonce: [UInt8]) throws -> [UInt8] {
        guard let encryptionKey, let cipher, cipher.isGCM else {
            throw SMBError.unsupported("The server requires encryption with a cipher this client doesn't support.")
        }
        var header = ByteWriter(capacity: Self.transformHeaderSize)
        header.u32(SMB2Header.transformID)
        header.zeros(16)                 // Signature (the GCM tag), filled below
        header.append(nonce)             // 12 bytes
        header.zeros(4)                  // rest of the 16-byte nonce field
        header.u32(UInt32(plaintext.count))
        header.u16(0)
        header.u16(0x0001)               // Flags: encrypted
        header.u64(sessionID)
        let aad = header.bytes[20..<52]
        let sealed = try SMBCrypto.gcmSeal(key: encryptionKey, nonce: nonce, plaintext: plaintext, aad: aad)

        var frame = [UInt8]()
        frame.reserveCapacity(SMBRequest.prefixSize + Self.transformHeaderSize + sealed.ciphertext.count)
        let length = Self.transformHeaderSize + sealed.ciphertext.count
        frame.append(0)
        frame.append(UInt8(truncatingIfNeeded: length >> 16))
        frame.append(UInt8(truncatingIfNeeded: length >> 8))
        frame.append(UInt8(truncatingIfNeeded: length))
        frame.append(contentsOf: header.bytes[0..<4])
        frame.append(contentsOf: sealed.tag)
        frame.append(contentsOf: header.bytes[20..<52])
        frame.append(contentsOf: sealed.ciphertext)
        return frame
    }

    /// Decrypts a received TRANSFORM_HEADER frame (without the Direct TCP prefix).
    func open(_ frame: [UInt8]) throws -> [UInt8] {
        guard let decryptionKey, let cipher, cipher.isGCM else {
            throw SMBError.malformed("encrypted response without a negotiated GCM cipher")
        }
        let r = ByteReader(frame)
        guard frame.count >= Self.transformHeaderSize else { throw SMBError.malformed("short transform header") }
        let size = Int(try r.u32(36))
        guard size == frame.count - Self.transformHeaderSize else { throw SMBError.malformed("transform size mismatch") }
        let plain = try SMBCrypto.gcmOpen(key: decryptionKey, nonce: Array(frame[20..<32]),
                                          ciphertext: frame[Self.transformHeaderSize...], tag: frame[4..<20],
                                          aad: frame[20..<52])
        return [UInt8](plain)
    }
}
