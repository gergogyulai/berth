import Foundation
import Testing
@testable import BerthSMB

/// Symbolic links, extended attributes and named streams. The Samba buffers were captured
/// from Samba 4.19 (`[plain]` without VFS modules, `[mac]` with catia, fruit and streams_xattr).
@Suite struct MetadataTests {
    @Test func xsymLinksRoundTripInTheSmbfsFormat() throws {
        let file = try SymlinkCodec.xsym(target: "target.txt")
        #expect(file.count == 1067)
        let header = String(decoding: file.prefix(54), as: UTF8.self)
        #expect(header == "XSym\n0010\n4d6f333d2bc24ffddcca34414a0cb12d\ntarget.txt\n")
        #expect(file.suffix(1013).allSatisfy { $0 == 0x20 })
        #expect(SymlinkCodec.parseXSym(file) == "target.txt")

        let unicode = "../Média/ünïcode folder/a"
        #expect(SymlinkCodec.parseXSym(try SymlinkCodec.xsym(target: unicode)) == unicode)
        let longest = String(repeating: "x", count: 1024)
        #expect(SymlinkCodec.parseXSym(try SymlinkCodec.xsym(target: longest)) == longest)
        #expect(throws: SMBError.self) { try SymlinkCodec.xsym(target: String(repeating: "x", count: 1025)) }
        #expect(throws: SMBError.self) { try SymlinkCodec.xsym(target: "") }
    }

    @Test func xsymParserRejectsLookalikes() throws {
        var file = try SymlinkCodec.xsym(target: "target.txt")
        #expect(SymlinkCodec.parseXSym(file.dropLast()) == nil)       // wrong size
        file[43] = UInt8(ascii: "T")                                  // checksum no longer matches
        #expect(SymlinkCodec.parseXSym(file) == nil)
        #expect(SymlinkCodec.parseXSym([UInt8](repeating: 0x20, count: 1067)) == nil)
    }

    @Test func symlinkReparsePointsRoundTrip() throws {
        let data = SymlinkCodec.reparseData(relativeTarget: "../docs/target.txt")
        #expect(Array(data.prefix(4)) == [0x0C, 0x00, 0x00, 0xA0])     // IO_REPARSE_TAG_SYMLINK
        #expect(Int(data[4]) | Int(data[5]) << 8 == data.count - 8)
        #expect(Array(data[16..<20]) == [1, 0, 0, 0])                   // SYMLINK_FLAG_RELATIVE
        #expect(try SymlinkCodec.parseReparse(ByteReader(data)) == "../docs/target.txt")
    }

    @Test func parsesWindowsAndNFSReparsePoints() throws {
        // An absolute Windows link: no print name, substitute name with the NT prefix.
        let substitute = NTLMClient.utf16LE("\\??\\C:\\Users\\jo")
        var body = ByteWriter()
        body.u16(0)
        body.u16(UInt16(substitute.count))
        body.u16(UInt16(substitute.count))
        body.u16(0)
        body.u32(0)
        body.append(substitute)
        var w = ByteWriter()
        w.u32(SMBReparseTag.symlink)
        w.u16(UInt16(body.bytes.count))
        w.u16(0)
        w.append(body.bytes)
        #expect(try SymlinkCodec.parseReparse(ByteReader(w.bytes)) == "C:/Users/jo")

        // NFS_SPECFILE_LNK, as the Windows NFS server and SMB3 POSIX servers store links.
        let target = NTLMClient.utf16LE("/srv/data")
        var nfs = ByteWriter()
        nfs.u32(SMBReparseTag.nfs)
        nfs.u16(UInt16(8 + target.count))
        nfs.u16(0)
        nfs.u64(0x0000_0000_014B_4E4C)
        nfs.append(target)
        #expect(try SymlinkCodec.parseReparse(ByteReader(nfs.bytes)) == "/srv/data")

        // A junction is not a symlink for our purposes.
        var junction = ByteWriter()
        junction.u32(SMBReparseTag.mountPoint)
        junction.u16(8)
        junction.u16(0)
        junction.zeros(8)
        #expect(try SymlinkCodec.parseReparse(ByteReader(junction.bytes)) == nil)
    }

    @Test func symlinkHints() {
        let link = SMBItem(path: "a", fileID: 1, isDirectory: false, reparseTag: SMBReparseTag.symlink)
        #expect(link.isSymbolicLink && link.mightBeSymbolicLink && link.isReparsePoint)
        let xsymSized = SMBItem(path: "b", fileID: 2, isDirectory: false, size: 1067)
        #expect(!xsymSized.isSymbolicLink && xsymSized.mightBeSymbolicLink)
        #expect(!SMBItem(path: "c", fileID: 3, isDirectory: false, size: 1066).mightBeSymbolicLink)
        #expect(!SMBItem(path: "d", fileID: 4, isDirectory: true).mightBeSymbolicLink)
    }

    @Test func eaNamesAreEscapedToWhatSambaAccepts() {
        #expect(EACodec.encodeName("com.apple.metadata:_kMDItemUserTags") == "com.apple.metadata%3A_kMDItemUserTags")
        #expect(EACodec.encodeName("com.apple.FinderInfo") == "com.apple.FinderInfo")
        #expect(EACodec.encodeName("a b/c%d") == "a%20b%2Fc%25d")
        #expect(EACodec.encodeName("é") == "%C3%A9")
        for name in ["com.apple.metadata:_kMDItemUserTags", "a b/c%d", "é*?<>|", "plain", "100%"] {
            #expect(EACodec.decodeName(EACodec.encodeName(name)) == name)
        }
        #expect(EACodec.decodeName("bad%zzescape%4") == "bad%zzescape%4")
    }

    @Test func parsesSambaEAList() throws {
        let entries = try EACodec.parse(ByteReader(hex(
            "3800000000141a00636f6d2e6170706c652e46696e646572496e666f0076616c75652d636f6d2e6170706c652e46696e64"
                + "6572496e666f001000000000030100612e6200310000001000000000030200632e6400323200000000000000252b00636f"
                + "6d2e6170706c652e6d657461646174612533415f6b4d444974656d55736572546167730076616c75652d636f6d2e617070"
                + "6c652e6d657461646174612533415f6b4d444974656d5573657254616773")))
        #expect(entries.map(\.name) == ["com.apple.FinderInfo", "a.b", "c.d", "com.apple.metadata:_kMDItemUserTags"])
        #expect(entries[1].value == Array("1".utf8))
        #expect(entries[2].value == Array("22".utf8))
        #expect(entries[3].value == Array("value-com.apple.metadata%3A_kMDItemUserTags".utf8))
    }

    @Test func eaListsRoundTrip() throws {
        let entries: [(name: String, value: [UInt8])] = [("com.apple.metadata:_kMDItemUserTags", [1, 2, 3]),
                                                        ("x", []), ("long", [UInt8](repeating: 7, count: 300))]
        let encoded = try EACodec.encode(entries)
        // Entries are 4-byte aligned; the last one has NextEntryOffset 0.
        let first = Int(encoded[0]) | Int(encoded[1]) << 8
        #expect(first % 4 == 0 && first == 8 + 37 + 1 + 3 + 3)
        let decoded = try EACodec.parse(ByteReader(encoded))
        #expect(decoded.map(\.name) == entries.map(\.name))
        #expect(decoded.map(\.value) == entries.map(\.value))
        #expect(throws: SMBError.self) { try EACodec.encode([("big", [UInt8](repeating: 0, count: 70_000))]) }
    }

    @Test func parsesSambaStreamList() throws {
        let streams = try StreamCodec.parseStreams(ByteReader(hex(
            "4000000024000000050000000000000005000000000000003a00740065007300740022f0730074007200650061006d003a"
                + "002400440041005400410000000000280000000e000000030000000000000000200000000000003a003a002400440041"
                + "005400410000000000000000240000003c000000000000003c000000000000003a004100460050005f00410066007000"
                + "49006e0066006f003a0024004400410054004100")))
        #expect(streams.map(\.name) == ["test\u{F022}stream", "AFP_AfpInfo"])
        #expect(streams.map(\.size) == [5, 60])
        #expect(streams.map { StreamCodec.attributeName(forStream: $0.name) } == ["test:stream", "com.apple.FinderInfo"])
    }

    @Test func streamNamesUseTheSFMMapping() {
        #expect(StreamCodec.streamName(forAttribute: "com.apple.metadata:_kMDItemUserTags")
            == "com.apple.metadata\u{F022}_kMDItemUserTags")
        #expect(StreamCodec.streamName(forAttribute: "com.apple.FinderInfo") == "AFP_AfpInfo")
        #expect(StreamCodec.streamName(forAttribute: "com.apple.ResourceFork") == "AFP_Resource")
        #expect(StreamCodec.streamName(forAttribute: "trailing.") == "trailing\u{F029}")
        for name in ["a:b*c?d\"e<f>g|h", "plain.name", "with space ", "ctl\u{1}x", "com.apple.ResourceFork"] {
            #expect(StreamCodec.attributeName(forStream: StreamCodec.streamName(forAttribute: name)) == name)
        }
    }

    @Test func afpInfoWrapsFinderInfo() throws {
        let finderInfo = Array("TEXTttxt".utf8) + [UInt8](repeating: 0, count: 24)
        let afp = StreamCodec.afpInfo(finderInfo: finderInfo)
        #expect(afp.count == 60)
        // The bytes Samba's vfs_fruit accepts (signature "AFP\0", version 0x00010000 LE).
        #expect(Array(afp.prefix(16)) == hex("41465000000001000000000080000000"))
        #expect(StreamCodec.finderInfo(fromAfpInfo: afp) == finderInfo)
        #expect(StreamCodec.finderInfo(fromAfpInfo: Array(repeating: 0, count: 60)) == nil)
    }

    @Test func fsctlRequestLayout() {
        let input: [UInt8] = [1, 2, 3, 4]
        let request = Requests.fsctl(testFileIDForMetadata, code: SMBFSControl.setReparsePoint, input: input, maxOutput: 0)
        let b = Array(request.frame[(SMBRequest.prefixSize + SMB2.headerSize)...])
        #expect(b.count == 56 + input.count)
        #expect(Array(b[0..<2]) == [57, 0])
        #expect(Array(b[4..<8]) == [0xA4, 0x00, 0x09, 0x00])
        #expect(Array(b[24..<28]) == [120, 0, 0, 0])      // InputOffset: right after the fixed part
        #expect(Array(b[28..<32]) == [4, 0, 0, 0])
        #expect(Array(b[48..<52]) == [1, 0, 0, 0])        // SMB2_0_IOCTL_IS_FSCTL
        #expect(Array(b.suffix(4)) == input)
        #expect(request.command == .ioctl)
    }
}

private let testFileIDForMetadata = SMBFileID(persistent: 1, volatile: 2)
