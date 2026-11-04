import Foundation

/// Who to sign in as.
public enum SMBCredentials: Sendable, Hashable {
    case user(name: String, password: String, domain: String)
    /// The server's guest account (no password).
    case guest
    /// A null session.
    case anonymous

    public static func user(_ name: String, password: String) -> SMBCredentials {
        .user(name: name, password: password, domain: "")
    }
}

/// NTLMv2 client (MS-NLMP) including the AUTHENTICATE MIC and the SPNEGO mechListMIC.
struct NTLMClient {
    enum Flag {
        static let unicode: UInt32 = 0x0000_0001
        static let requestTarget: UInt32 = 0x0000_0004
        static let sign: UInt32 = 0x0000_0010
        static let seal: UInt32 = 0x0000_0020
        static let ntlm: UInt32 = 0x0000_0200
        static let anonymous: UInt32 = 0x0000_0800
        static let alwaysSign: UInt32 = 0x0000_8000
        static let extendedSessionSecurity: UInt32 = 0x0008_0000
        static let version: UInt32 = 0x0200_0000
        static let key128: UInt32 = 0x2000_0000
        static let keyExchange: UInt32 = 0x4000_0000
        static let key56: UInt32 = 0x8000_0000
    }

    static let requestedFlags: UInt32 = Flag.unicode | Flag.requestTarget | Flag.sign | Flag.seal | Flag.ntlm
        | Flag.alwaysSign | Flag.extendedSessionSecurity | Flag.version | Flag.key128 | Flag.keyExchange | Flag.key56

    /// Windows 10 build 19041, NTLM revision 15. Purely informational.
    static let version: [UInt8] = [10, 0, 0x61, 0x4A, 0, 0, 0, 0x0F]

    let credentials: SMBCredentials
    let workstation: String

    private(set) var negotiateMessage: [UInt8] = []
    /// The exported session key: the SMB session key once authentication succeeds.
    private(set) var sessionKey: [UInt8]?
    private(set) var negotiatedFlags: UInt32 = 0

    init(credentials: SMBCredentials, workstation: String) {
        self.credentials = credentials
        self.workstation = workstation
    }

    var isAnonymous: Bool {
        if case .anonymous = credentials { return true }
        return false
    }

    mutating func makeNegotiate() -> [UInt8] {
        var w = ByteWriter(capacity: 40)
        w.append(Array("NTLMSSP".utf8))
        w.u8(0)
        w.u32(1)
        w.u32(Self.requestedFlags)
        w.zeros(16) // domain + workstation fields (not supplied)
        w.append(Self.version)
        negotiateMessage = w.bytes
        return negotiateMessage
    }

    mutating func makeAuthenticate(challenge: [UInt8]) throws -> [UInt8] {
        let r = ByteReader(challenge)
        guard challenge.count >= 48, challenge.starts(with: Array("NTLMSSP".utf8)), try r.u32(8) == 2 else {
            throw SMBError.malformed("not an NTLM CHALLENGE message")
        }
        let serverFlags = try r.u32(20)
        let serverChallenge = try r.array(24, 8)
        let targetInfoLength = Int(try r.u16(40))
        let targetInfoOffset = Int(try r.u32(44))
        var targetInfo: [UInt8] = []
        if targetInfoLength > 0 { targetInfo = try r.array(targetInfoOffset, targetInfoLength) }

        if isAnonymous { return makeAnonymousAuthenticate(serverFlags: serverFlags) }

        let user: String
        let password: String
        let domain: String
        switch credentials {
        case .user(let name, let pass, let dom):
            user = name
            password = pass
            domain = dom
        case .guest:
            user = "Guest"
            password = ""
            domain = ""
        case .anonymous:
            return makeAnonymousAuthenticate(serverFlags: serverFlags)
        }

        // Rebuild the AV pairs: keep the server's, drop its MsvAvFlags, add ours (MIC present).
        var pairs: [(UInt16, [UInt8])] = []
        var timestamp: [UInt8]?
        let avReader = ByteReader(targetInfo)
        var cursor = 0
        while avReader.contains(cursor, 4) {
            let id = try avReader.u16(cursor)
            let length = Int(try avReader.u16(cursor + 2))
            let value = try avReader.array(cursor + 4, length)
            cursor += 4 + length
            if id == 0 { break }
            if id == 7 { timestamp = value }
            if id == 6 { continue }
            pairs.append((id, value))
        }
        pairs.append((6, [0x02, 0, 0, 0]))
        var av = ByteWriter(capacity: targetInfo.count + 16)
        for (id, value) in pairs {
            av.u16(id)
            av.u16(UInt16(value.count))
            av.append(value)
        }
        av.zeros(4) // MsvAvEOL

        let time: [UInt8]
        if let timestamp, timestamp.count == 8 {
            time = timestamp
        } else {
            var t = ByteWriter(capacity: 8)
            t.u64(FileTime.value(Date()))
            time = t.bytes
        }

        let v2 = Self.ntlmv2(user: user, domain: domain, password: password, serverChallenge: serverChallenge,
                             clientChallenge: SMBCrypto.randomBytes(8), timestamp: time, targetInfo: av.bytes)
        let ntResponse = v2.ntResponse
        // With MsvAvTimestamp present the LM response must be all zeros (MS-NLMP 3.1.5.1.2).
        let lmResponse = [UInt8](repeating: 0, count: 24)
        let sessionBaseKey = v2.sessionBaseKey

        let flags = Self.requestedFlags & serverFlags
        let exportedKey: [UInt8]
        let encryptedKey: [UInt8]
        if flags & Flag.keyExchange != 0 {
            exportedKey = SMBCrypto.randomBytes(16)
            var rc4 = RC4(key: sessionBaseKey)
            encryptedKey = rc4.process(exportedKey)
        } else {
            exportedKey = sessionBaseKey
            encryptedKey = []
        }

        var message = Self.authenticateMessage(
            flags: flags, lm: lmResponse, nt: ntResponse, domain: Self.utf16LE(domain),
            user: Self.utf16LE(user), workstation: Self.utf16LE(workstation), sessionKey: encryptedKey)
        let mic = SMBCrypto.hmacMD5(key: exportedKey, negotiateMessage + challenge + message)
        message.replaceSubrange(72..<88, with: mic)

        negotiatedFlags = flags
        sessionKey = exportedKey
        return message
    }

    /// The NTLMv2 response computation (MS-NLMP 3.3.2), separated out for test vectors.
    static func ntlmv2(user: String, domain: String, password: String, serverChallenge: [UInt8],
                       clientChallenge: [UInt8], timestamp: [UInt8],
                       targetInfo: [UInt8]) -> (proof: [UInt8], ntResponse: [UInt8], sessionBaseKey: [UInt8]) {
        let ntHash = MD4.hash(utf16LE(password))
        let responseKey = SMBCrypto.hmacMD5(key: ntHash, utf16LE(user.uppercased() + domain))
        var temp = ByteWriter(capacity: 32 + targetInfo.count)
        temp.u8(1)
        temp.u8(1)
        temp.zeros(6)
        temp.append(timestamp)
        temp.append(clientChallenge)
        temp.zeros(4)
        temp.append(targetInfo)
        temp.zeros(4)
        let proof = SMBCrypto.hmacMD5(key: responseKey, serverChallenge + temp.bytes)
        return (proof, proof + temp.bytes, SMBCrypto.hmacMD5(key: responseKey, proof))
    }

    private mutating func makeAnonymousAuthenticate(serverFlags: UInt32) -> [UInt8] {
        let flags = (Self.requestedFlags & serverFlags & ~Flag.keyExchange) | Flag.anonymous
        negotiatedFlags = flags
        sessionKey = nil
        return Self.authenticateMessage(flags: flags, lm: [0], nt: [], domain: [], user: [],
                                        workstation: Self.utf16LE(workstation), sessionKey: [])
    }

    /// Fixed 88-byte header (with Version and a zeroed MIC) followed by the payload.
    private static func authenticateMessage(flags: UInt32, lm: [UInt8], nt: [UInt8], domain: [UInt8],
                                            user: [UInt8], workstation: [UInt8], sessionKey: [UInt8]) -> [UInt8] {
        let fields = [lm, nt, domain, user, workstation, sessionKey]
        var w = ByteWriter(capacity: 88 + fields.reduce(0) { $0 + $1.count })
        w.append(Array("NTLMSSP".utf8))
        w.u8(0)
        w.u32(3)
        var offset = 88
        for field in fields {
            w.u16(UInt16(field.count))
            w.u16(UInt16(field.count))
            w.u32(UInt32(offset))
            offset += field.count
        }
        w.u32(flags)
        w.append(version)
        w.zeros(16) // MIC, filled in afterwards
        for field in fields { w.append(field) }
        return w.bytes
    }

    /// GSS_GetMIC over the SPNEGO MechTypeList (MS-NLMP 3.4.4.2, sequence number 0).
    func mechListMIC(over data: [UInt8]) -> [UInt8]? {
        guard let sessionKey, negotiatedFlags & Flag.sign != 0 else { return nil }
        return Self.mechListMIC(sessionKey: sessionKey, flags: negotiatedFlags, data: data)
    }

    static func mechListMIC(sessionKey: [UInt8], flags negotiatedFlags: UInt32, data: [UInt8]) -> [UInt8] {
        let signingKey = SMBCrypto.md5(sessionKey + Array("session key to client-to-server signing key magic constant".utf8) + [0])
        var sealBase = sessionKey
        if negotiatedFlags & Flag.key128 == 0 {
            sealBase = Array(sessionKey.prefix(negotiatedFlags & Flag.key56 != 0 ? 7 : 5))
        }
        let sealingKey = SMBCrypto.md5(sealBase + Array("session key to client-to-server sealing key magic constant".utf8) + [0])
        let sequence: [UInt8] = [0, 0, 0, 0]
        var checksum = Array(SMBCrypto.hmacMD5(key: signingKey, sequence + data).prefix(8))
        if negotiatedFlags & Flag.keyExchange != 0 {
            var rc4 = RC4(key: sealingKey)
            checksum = rc4.process(checksum)
        }
        return [1, 0, 0, 0] + checksum + sequence
    }

    static func utf16LE(_ string: String) -> [UInt8] {
        var w = ByteWriter(capacity: string.utf16.count * 2)
        w.utf16(string)
        return w.bytes
    }
}
