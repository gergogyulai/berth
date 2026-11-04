import Foundation
import Testing
@testable import BerthSMB

private func body(_ request: SMBRequest) -> [UInt8] {
    Array(request.frame[(SMBRequest.prefixSize + SMB2.headerSize)...])
}

private func message(_ bytes: [UInt8]) throws -> SMBMessage {
    let reader = ByteReader(bytes)
    return SMBMessage(reader: reader, header: try SMB2Header(reader), wasEncrypted: false)
}

private let testFileID = SMBFileID(persistent: 0x0102_0304_0506_0708, volatile: 0x1112_1314_1516_1718)

@Suite struct CryptoTests {
    @Test func md4MatchesRFC1320() {
        #expect(MD4.hash([]) == hex("31d6cfe0d16ae931b73c59d7e0c089c0"))
        #expect(MD4.hash(Array("abc".utf8)) == hex("a448017aaf21d8525fc10ae87aa6729d"))
        #expect(MD4.hash(Array("message digest".utf8)) == hex("d9130a8164549fe818874806e1c7014b"))
        #expect(MD4.hash(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8))
            == hex("e33b4ddc9c38f2199c3e7b164fcc0536"))
    }

    @Test func rc4MatchesKnownVector() {
        var rc4 = RC4(key: Array("Key".utf8))
        #expect(rc4.process(Array("Plaintext".utf8)) == hex("bbf316e8d940af0ad3"))
    }

    @Test func aesCMACMatchesRFC4493() {
        let cmac = AESCMAC(key: hex("2b7e151628aed2a6abf7158809cf4f3c"))
        let m = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
        #expect(cmac.mac([]) == hex("bb1d6929e95937287fa37d129b756746"))
        #expect(cmac.mac(Array(m.prefix(16))) == hex("070a16b46b4d4144f79bdd9dd04a287c"))
        #expect(cmac.mac(Array(m.prefix(40))) == hex("dfa66747de9ae63030ca32611497c827"))
        #expect(cmac.mac(m) == hex("51f0bebf7e3b9d92fc49741779363cfe"))
    }

    @Test func kdfMatchesPrototype() {
        let key = Array(UInt8(0)..<16)
        #expect(SMBCrypto.kdf(key: key, label: Array(ascii: "SMBSigningKey", nulTerminated: true),
                              context: Golden.preauth, bits: 128) == Golden.kdfSigning311)
        #expect(SMBCrypto.kdf(key: key, label: Array(ascii: "SMBS2CCipherKey", nulTerminated: true),
                              context: Golden.preauth, bits: 256) == Golden.kdfS2C256)
        let security311 = SessionSecurity.derive(sessionKey: key, sessionID: 1, dialect: .smb311,
                                                 signingAlgorithm: .aesGMAC, cipher: .aes128GCM, preauthHash: Golden.preauth)
        #expect(security311.signingKey == Golden.kdfSigning311)
        #expect(security311.encryptionKey == Golden.kdfC2S128)
        let security30 = SessionSecurity.derive(sessionKey: key, sessionID: 1, dialect: .smb300,
                                                signingAlgorithm: .aesCMAC, cipher: nil, preauthHash: [])
        #expect(security30.signingKey == Golden.kdfSigning30)
        #expect(security30.encryptionKey == nil)
    }
}

@Suite struct NTLMTests {
    /// MS-NLMP 4.2.4 (NTLMv2 authentication) test vector.
    @Test func ntlmv2MatchesSpecVector() {
        var av = ByteWriter()
        av.u16(2)
        av.u16(12)
        av.utf16("Domain")
        av.u16(1)
        av.u16(12)
        av.utf16("Server")
        av.zeros(4)
        let result = NTLMClient.ntlmv2(user: "User", domain: "Domain", password: "Password",
                                       serverChallenge: hex("0123456789abcdef"), clientChallenge: hex("aaaaaaaaaaaaaaaa"),
                                       timestamp: [UInt8](repeating: 0, count: 8), targetInfo: av.bytes)
        #expect(result.proof == hex("68cd0ab851e51c96aabc927bebef6a1c"))
        #expect(result.sessionBaseKey == hex("8de40ccadbc14a82f15cb0ad0de95ca3"))
    }

    @Test func negotiateMessageMatchesPrototype() {
        var ntlm = NTLMClient(credentials: .user("u", password: "p"), workstation: "BERTH")
        #expect(ntlm.makeNegotiate() == Golden.ntlmNegotiate)
    }

    @Test func mechListMICMatchesPrototype() {
        let mic = NTLMClient.mechListMIC(sessionKey: Array(UInt8(50)..<66), flags: NTLMClient.requestedFlags,
                                         data: SPNEGO.mechTypes)
        #expect(mic == Golden.mechListMIC)
    }

    @Test func authenticateAgainstSambaChallenge() throws {
        let spnego = try SPNEGO.parseResponse(Golden.sambaChallengeSPNEGO)
        let challenge = try #require(spnego.responseToken)
        var ntlm = NTLMClient(credentials: .user("berth", password: "p@ss w0rd"), workstation: "BERTH")
        _ = ntlm.makeNegotiate()
        let message = try ntlm.makeAuthenticate(challenge: challenge)
        #expect(message.starts(with: Array("NTLMSSP".utf8) + [0, 3, 0, 0, 0]))
        #expect(ntlm.sessionKey?.count == 16)
        // Samba offers key exchange, signing and 128-bit keys.
        #expect(ntlm.negotiatedFlags & NTLMClient.Flag.keyExchange != 0)
        #expect(ntlm.mechListMIC(over: SPNEGO.mechTypes)?.count == 16)
    }

    @Test func anonymousAuthenticateCarriesNoKey() throws {
        let challenge = try #require(try SPNEGO.parseResponse(Golden.sambaChallengeSPNEGO).responseToken)
        var ntlm = NTLMClient(credentials: .anonymous, workstation: "BERTH")
        _ = ntlm.makeNegotiate()
        let message = try ntlm.makeAuthenticate(challenge: challenge)
        #expect(ntlm.sessionKey == nil)
        #expect(ntlm.mechListMIC(over: SPNEGO.mechTypes) == nil)
        #expect(message.count == 88 + 1 + 10) // LM Z(1) + "BERTH" in UTF-16
    }

    @Test func spnegoTokensMatchPrototype() {
        #expect(SPNEGO.initToken(mechToken: Golden.ntlmNegotiate) == Golden.spnegoInit)
        #expect(SPNEGO.responseToken([1, 2, 3], mechListMIC: [UInt8](repeating: 9, count: 16)) == Golden.spnegoResp)
    }
}

@Suite struct EncodingTests {
    @Test func requestBodiesMatchPrototype() {
        #expect(body(Requests.create(path: "dir\\file.txt", access: SMBAccess(rawValue: 0x81), disposition: .open,
                                     options: [.nonDirectoryFile])) == Golden.createBody)
        #expect(body(Requests.read(testFileID, offset: 0x10000, length: 65536)) == Golden.readBody)
        #expect(body(Requests.write(testFileID, offset: 0x20, length: 3) { buffer in
            buffer[0] = 1
            buffer[1] = 2
            buffer[2] = 3
        }) == Golden.writeBody)
        #expect(body(Requests.queryDirectory(.related, infoClass: .idFullDirectory, flags: SMBQueryDirectoryFlag.restartScans,
                                             pattern: "*", outputLength: 65536)) == Golden.queryDirectoryBody)
        #expect(body(Requests.setInfo(testFileID, infoClass: .rename,
                                      buffer: Requests.renameInfo(target: "a\\b.txt", replaceIfExists: true))) == Golden.renameSetInfoBody)
        #expect(body(Requests.close(testFileID, postQueryAttributes: true)) == Golden.closeBody)
        #expect(body(Requests.treeConnect(path: "\\\\nas\\Media")) == Golden.treeConnectBody)
        #expect(body(Requests.sessionSetup(blob: [0xAA, 0xBB], securityMode: 1)) == Golden.sessionSetupBody)
        #expect(body(Requests.negotiate(dialects: SMBDialect.all, securityMode: 1,
                                        capabilities: SMB2Capability.largeMTU | SMB2Capability.encryption,
                                        clientGUID: Array(UInt8(0)..<16), salt: Array(UInt8(32)..<64))) == Golden.negotiateBody)
    }

    @Test func creditChargesFollowPayload() {
        #expect(Requests.read(testFileID, offset: 0, length: 65536).creditCharge == 1)
        #expect(Requests.read(testFileID, offset: 0, length: 65537).creditCharge == 2)
        #expect(Requests.read(testFileID, offset: 0, length: 8 << 20).creditCharge == 128)
        #expect(Requests.queryDirectory(.related, infoClass: .idFullDirectory, flags: 0, pattern: "*",
                                        outputLength: 256 * 1024).creditCharge == 4)
    }

    @Test func headerMatchesPrototype() {
        var frame = [UInt8](repeating: 0, count: 4 + 64)
        SMBConnection.writeHeader(&frame, at: 4, command: .create, charge: 2, creditRequest: 66,
                                  flags: SMB2HeaderFlag.relatedOperations, next: 120, messageID: 7,
                                  treeID: 0x1122_3344, sessionID: 0x0102_0304_0506_0708)
        #expect(Array(frame[4...]) == Golden.header)
    }

    @Test func signaturesMatchPrototype() throws {
        let unsigned = Golden.header + Golden.createBody
        let key = Array(UInt8(100)..<116)
        for (algorithm, expected) in [(SMBSigningAlgorithm.aesGMAC, Golden.signed_gmac),
                                      (.aesCMAC, Golden.signed_cmac), (.hmacSHA256, Golden.signed_hmac)] {
            let security = SessionSecurity(sessionID: 1, dialect: .smb311, signingAlgorithm: algorithm, signingKey: key,
                                           cmac: algorithm == .aesCMAC ? AESCMAC(key: key) : nil, cipher: nil,
                                           encryptionKey: nil, decryptionKey: nil, signRequests: true, encryptRequests: false)
            var buffer = unsigned
            try security.sign(&buffer, range: 0..<buffer.count)
            #expect(buffer == expected, "\(algorithm)")
            var received = expected
            #expect(try security.verify(&received, range: 0..<received.count))
            var tampered = expected
            tampered[100] ^= 1
            #expect(try !security.verify(&tampered, range: 0..<tampered.count))
        }
    }

    @Test func sealingMatchesPrototypeAndRoundTrips() throws {
        let plain = Golden.header + Golden.createBody
        let security = SessionSecurity(sessionID: 0x0102_0304_0506_0708, dialect: .smb311, signingAlgorithm: .aesGMAC,
                                       signingKey: [], cmac: nil, cipher: .aes128GCM, encryptionKey: Golden.kdfC2S128,
                                       decryptionKey: Golden.kdfC2S128, signRequests: false, encryptRequests: true)
        let frame = try plain.withUnsafeBytes { try security.seal($0, nonce: Array(UInt8(200)..<212)) }
        #expect(frame == Golden.sealedFrame)
        #expect(try security.open(Array(frame[4...])) == plain)
    }
}

@Suite struct ParsingTests {
    @Test func parsesSambaNegotiateResponse() throws {
        let response = try NegotiateResponse(try message(Golden.sambaNegotiateResponse))
        #expect(response.dialect == .smb311)
        #expect(response.maxReadSize == 8 << 20)
        #expect(response.maxWriteSize == 8 << 20)
        #expect(response.securityMode & SMB2SecurityMode.signingRequired != 0)
        #expect(response.signingAlgorithm == .aesGMAC)
        #expect(response.cipher == .aes128GCM)
        #expect(response.capabilities & SMB2Capability.largeMTU != 0)
        #expect(!response.securityBlob.isEmpty)
    }

    @Test func parsesSambaDirectoryListing() throws {
        let entries = try DirectoryParser.entries(ByteReader(Golden.sambaDirectoryBuffer))
        #expect(entries.map(\.name) == [".", "..", "sub", "héllo wörld.txt"])
        let file = try #require(entries.last)
        #expect(file.stat.endOfFile == 1234)
        #expect(file.fileID == 573_865)
        #expect(FileTime.date(file.stat.lastWriteTime) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entries[2].stat.attributes.contains(.directory))
        let item = SMBItem(path: SMBPath.join("golden", file.name), stat: file.stat, fileID: file.fileID)
        #expect(item.path == "golden/héllo wörld.txt")
        #expect(!item.isDirectory)
    }

    @Test func parsesSambaChangeNotification() throws {
        let entries = try NotifyParser.entries(ByteReader(Golden.sambaNotifyBuffer))
        #expect(entries.count == 1)
        #expect(entries.first?.0 == .removed)
        #expect(entries.first?.1 == "héllo wörld.txt")
    }

    @Test func fileTimeRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        #expect(FileTime.value(date) == 133_444_736_005_000_000)
        #expect(FileTime.date(FileTime.value(date)) == date)
        #expect(FileTime.date(0) == nil)
    }

    @Test func pathsNormalize() {
        #expect(SMBPath.wire("/a//b/c/") == "a\\b\\c")
        #expect(SMBPath.join("", "x") == "x")
        #expect(SMBPath.join("a/b", "c") == "a/b/c")
        #expect(SMBPath.parent("a/b/c") == "a/b")
        #expect(SMBPath.parent("a") == "")
        #expect(SMBPath.fromWire("a\\b") == "a/b")
        // Decomposed (as macOS sometimes hands out) becomes precomposed on the wire. Compare
        // code units: Swift's String equality would treat both forms as equal.
        #expect(Array(SMBPath.wire("e\u{301}").utf16) == [0xE9])
    }

    @Test func derRejectsTruncatedInput() {
        #expect(throws: SMBError.self) { try SPNEGO.parseResponse([0xA1, 0x05, 0x30]) }
        #expect(throws: SMBError.self) { try DER.read([0x30, 0x84, 0xFF], at: 0) }
    }
}
