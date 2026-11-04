import Foundation

/// What was negotiated for a connected share. Shown in Berth's inspector and logs.
public struct SMBConnectionInfo: Sendable, Hashable {
    public var dialect: SMBDialect
    /// Signing algorithm in use, nil when requests aren't signed.
    public var signing: SMBSigningAlgorithm?
    /// Cipher in use, nil when traffic isn't encrypted.
    public var encryption: SMBCipher?
    public var maxReadSize: Int
    public var maxWriteSize: Int
    public var maxTransactSize: Int
    /// Read/write size this client actually uses per request.
    public var ioSize: Int
    public var supportsMultiCredit: Bool
    public var isGuest: Bool
    public var isAnonymous: Bool
    /// The share's maximal access does not include writing.
    public var isReadOnly: Bool
    public var serverGUID: UUID
    public var remote: String

    public var summary: String {
        var parts = ["SMB \(dialect)"]
        if let encryption { parts.append(encryption.description) } else if let signing { parts.append("signed (\(signing))") }
        if isGuest { parts.append("guest") }
        parts.append("\(ioSize / 1024) KiB I/O")
        return parts.joined(separator: " · ")
    }
}

struct SecurityPolicy: Sendable {
    var requireSigning: Bool
    var requireEncryption: Bool
}

extension SMBConnection {
    struct Negotiated {
        var response: NegotiateResponse
        var preauthHash: [UInt8]
    }

    func negotiate(dialects: [SMBDialect], policy: SecurityPolicy) async throws -> Negotiated {
        let securityMode = policy.requireSigning
            ? SMB2SecurityMode.signingEnabled | SMB2SecurityMode.signingRequired
            : SMB2SecurityMode.signingEnabled
        let request = Requests.negotiate(
            dialects: dialects, securityMode: securityMode,
            capabilities: SMB2Capability.largeMTU | SMB2Capability.encryption,
            clientGUID: SMBCrypto.randomBytes(16), salt: SMBCrypto.randomBytes(32))
        let result = try await send([request], captureSent: true)
        let message = result.responses[0]
        try message.check()
        let response = try NegotiateResponse(message)
        guard dialects.contains(response.dialect) else {
            throw SMBError.unsupported("The server chose SMB dialect \(response.dialect), which wasn't offered.")
        }
        var hash = [UInt8](repeating: 0, count: 64)
        if response.dialect == .smb311, let sent = result.sent {
            hash = SMBCrypto.sha512(hash, sent)
            hash = SMBCrypto.sha512(hash, message.bytes)
        }
        setDialect(response.dialect)
        return Negotiated(response: response, preauthHash: hash)
    }

    struct Session {
        var sessionID: UInt64
        var isGuest: Bool
        var isAnonymous: Bool
    }

    /// NTLMv2 over SPNEGO (two legs), deriving and installing the signing/sealing keys.
    func authenticate(credentials: SMBCredentials, workstation: String, negotiated: Negotiated,
                      policy: SecurityPolicy) async throws -> Session {
        let dialect = negotiated.response.dialect
        let is311 = dialect == .smb311
        var ntlm = NTLMClient(credentials: credentials, workstation: workstation)
        let securityMode: UInt8 = policy.requireSigning ? 0x03 : 0x01
        var hash = negotiated.preauthHash

        // Leg 1: NEGOTIATE → CHALLENGE.
        let first = Requests.sessionSetup(blob: SPNEGO.initToken(mechToken: ntlm.makeNegotiate()), securityMode: securityMode)
        let leg1 = try await send([first], captureSent: true)
        let reply1 = leg1.responses[0]
        guard reply1.status == .moreProcessingRequired else {
            throw reply1.status.isError ? SMBError.status(reply1.status) : SMBError.malformed("unexpected SESSION_SETUP reply")
        }
        if is311, let sent = leg1.sent {
            hash = SMBCrypto.sha512(hash, sent)
            hash = SMBCrypto.sha512(hash, reply1.bytes)
        }
        setSessionID(reply1.header.sessionID)
        let blob1 = try SessionSetupResponse(reply1).securityBlob
        let rawNTLM = blob1.starts(with: Array("NTLMSSP".utf8))
        let challenge: [UInt8]
        if rawNTLM {
            challenge = blob1
        } else {
            guard let token = try SPNEGO.parseResponse(blob1).responseToken else {
                throw SMBError.unsupported("The server did not offer NTLM authentication (Kerberos-only servers aren't supported).")
            }
            challenge = token
        }

        // Leg 2: AUTHENTICATE.
        let authenticate = try ntlm.makeAuthenticate(challenge: challenge)
        let blob2 = rawNTLM
            ? authenticate
            : SPNEGO.responseToken(authenticate, mechListMIC: ntlm.mechListMIC(over: SPNEGO.mechTypes))
        let second = Requests.sessionSetup(blob: blob2, securityMode: securityMode)
        let leg2 = try await send([second], captureSent: true)
        let reply2 = leg2.responses[0]
        if reply2.status.isError { throw SMBError.status(reply2.status) }
        guard reply2.status == .success else { throw SMBError.unsupported("Multi-leg authentication isn't supported.") }
        if is311, let sent = leg2.sent {
            // The final (successful) response is not part of the hash.
            hash = SMBCrypto.sha512(hash, sent)
        }

        let flags = try SessionSetupResponse(reply2).sessionFlags
        let isGuest = flags & SMB2SessionFlag.isGuest != 0
        let isAnonymous = ntlm.isAnonymous || flags & SMB2SessionFlag.isNull != 0
        let serverWantsEncryption = flags & SMB2SessionFlag.encryptData != 0
        let serverRequiresSigning = negotiated.response.securityMode & SMB2SecurityMode.signingRequired != 0

        if let key = ntlm.sessionKey, !isGuest, !isAnonymous {
            let algorithm: SMBSigningAlgorithm
            if is311 {
                algorithm = negotiated.response.signingAlgorithm ?? .aesCMAC
            } else {
                algorithm = dialect.isSMB3 ? .aesCMAC : .hmacSHA256
            }
            var security = SessionSecurity.derive(
                sessionKey: key, sessionID: reply2.header.sessionID, dialect: dialect, signingAlgorithm: algorithm,
                cipher: is311 ? negotiated.response.cipher : nil, preauthHash: hash)

            // The server signs the final response with the new key; checking it proves both
            // sides derived the same keys from an untampered negotiation.
            if reply2.header.isSigned {
                var copy = Array(reply2.bytes)
                guard try security.verify(&copy, range: 0..<copy.count) else { throw SMBError.signatureMismatch }
            }
            security.signRequests = serverRequiresSigning || policy.requireSigning
            security.encryptRequests = serverWantsEncryption || policy.requireEncryption
            if security.encryptRequests && !security.canEncrypt {
                throw SMBError.unsupported(dialect.isSMB3 && !is311
                    ? "The server requires SMB 3.0 encryption (AES-CCM), which Berth's SMB client doesn't support. Use the macOS SMB backend for this share."
                    : "The server requires encryption but no common cipher was negotiated.")
            }
            installSecurity(security)
        } else {
            if serverWantsEncryption || policy.requireEncryption {
                throw SMBError.unsupported("Guest and anonymous sessions can't be encrypted.")
            }
            if policy.requireSigning {
                throw SMBError.unsupported("Guest and anonymous sessions can't be signed.")
            }
            installSecurity(nil)
        }
        return Session(sessionID: reply2.header.sessionID, isGuest: isGuest, isAnonymous: isAnonymous)
    }

    struct Tree {
        var treeID: UInt32
        var response: TreeConnectResponse
    }

    func treeConnect(host: String, share: String) async throws -> Tree {
        let server = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let message = try await send(Requests.treeConnect(path: "\\\\\(server)\\\(share)"))
        try message.check()
        let response = try TreeConnectResponse(message)
        guard response.shareType == 0x01 else {
            throw SMBError.unsupported("“\(share)” is not a disk share.")
        }
        if response.shareFlags & SMB2ShareFlag.encryptData != 0 {
            guard var security = self.security, security.canEncrypt else {
                throw SMBError.unsupported("The share requires encryption, which isn't available for this session.")
            }
            security.encryptRequests = true
            installSecurity(security)
        }
        return Tree(treeID: message.header.treeID, response: response)
    }

    func logoff() async {
        _ = try? await send(Requests.logoff())
    }
}
