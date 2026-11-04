import Foundation
import Testing
@testable import BerthSMB

/// Runs against a real server when BERTH_SMB_TEST_URL is set, e.g.
/// `BERTH_SMB_TEST_URL='smb://user:pass@127.0.0.1:4450/share' swift test`.
/// BERTH_SMB_TEST_ENCRYPTED_URL can point at a share with `smb encrypt = required`, and
/// BERTH_SMB_TEST_STREAMS_URL at one with named streams (`vfs objects = catia fruit streams_xattr`).
/// The main share is expected to have no named streams, so EAs carry the extended attributes.
private let testURL = ProcessInfo.processInfo.environment["BERTH_SMB_TEST_URL"]
private let encryptedURL = ProcessInfo.processInfo.environment["BERTH_SMB_TEST_ENCRYPTED_URL"]
private let streamsURL = ProcessInfo.processInfo.environment["BERTH_SMB_TEST_STREAMS_URL"]

private func makeClient(_ url: String) throws -> SMBClient {
    let configuration = try #require(SMBClient.Configuration(url: url))
    return SMBClient(configuration)
}

private func scratchFile(size: Int) throws -> (URL, [UInt8]) {
    var generator = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 0, count: size)
    for i in stride(from: 0, to: size, by: 8) {
        var value = generator.next()
        withUnsafeBytes(of: &value) { raw in
            for j in 0..<min(8, size - i) { bytes[i + j] = raw[j] }
        }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("berth-smb-test-\(UUID().uuidString)")
    try Data(bytes).write(to: url)
    return (url, bytes)
}

@Suite(.enabled(if: testURL != nil), .serialized)
struct IntegrationTests {
    @Test func fullFileLifecycle() async throws {
        let client = try makeClient(testURL!)
        let info = try await client.connect()
        #expect(info.dialect >= .smb210)

        let root = "berth-it-\(UUID().uuidString.prefix(8))"
        try await client.createDirectory(at: root)
        defer { Task { try? await client.removeItem(at: root, recursive: true, ignoreMissing: true) } }

        // Upload / download 24 MiB + a bit through the pipelined path.
        let (local, bytes) = try scratchFile(size: 24 << 20 | 12_345)
        defer { try? FileManager.default.removeItem(at: local) }
        let uploaded = try await client.upload(local, to: "\(root)/big.bin")
        #expect(uploaded.size == Int64(bytes.count))
        #expect(uploaded.fileID != 0)

        let back = FileManager.default.temporaryDirectory.appendingPathComponent("berth-smb-back-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: back) }
        let downloaded = try await client.download("\(root)/big.bin", to: back)
        #expect(downloaded.size == uploaded.size)
        #expect(try Data(contentsOf: back) == Data(bytes))

        // Listing, rename, timestamps.
        try await client.write(Array("hello".utf8), to: "\(root)/héllo.txt")
        let listing = try await client.contentsOfDirectory(at: root)
        #expect(Set(listing.map(\.name)) == ["big.bin", "héllo.txt"])
        #expect(!listing.contains { $0.name.hasPrefix(SMBClient.temporaryPrefix) })

        let moved = try await client.moveItem(at: "\(root)/héllo.txt", to: "\(root)/renamed.txt")
        #expect(moved.name == "renamed.txt")
        #expect(try await client.contents(of: "\(root)/renamed.txt") == Array("hello".utf8))
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        let touched = try await client.setAttributes(at: "\(root)/renamed.txt", modificationDate: stamp)
        #expect(touched.modificationDate == stamp)

        // Replacing keeps a single item; refusing to replace reports the collision.
        _ = try await client.write(Array("v2".utf8), to: "\(root)/renamed.txt")
        await #expect(throws: SMBError.status(.objectNameCollision)) {
            try await client.write(Array("v3".utf8), to: "\(root)/renamed.txt", replaceExisting: false)
        }
        #expect(try await client.contents(of: "\(root)/renamed.txt") == Array("v2".utf8))

        // Recursive delete.
        try await client.createDirectory(at: "\(root)/a/")
        try await client.createDirectory(at: "\(root)/a/b")
        try await client.write([1, 2, 3], to: "\(root)/a/b/c.bin")
        await #expect(throws: SMBError.status(.directoryNotEmpty)) {
            try await client.removeItem(at: "\(root)/a")
        }
        try await client.removeItem(at: "\(root)/a", recursive: true)
        #expect(try await !client.exists("\(root)/a"))

        let space = try await client.spaceInfo()
        #expect(space.totalBytes > 0)
        _ = try await client.echo()
        await client.disconnect()
    }

    @Test func manyConcurrentMetadataOperationsShareOneConnection() async throws {
        let client = try makeClient(testURL!)
        let root = "berth-it-\(UUID().uuidString.prefix(8))"
        try await client.createDirectory(at: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { _ = try await client.write([UInt8(i & 0xFF)], to: "\(root)/f\(i)") }
            }
            try await group.waitForAll()
        }
        #expect(try await client.contentsOfDirectory(at: root).count == 200)
        try await client.removeItem(at: root, recursive: true)
    }

    @Test func changeNotificationsArrive() async throws {
        let client = try makeClient(testURL!)
        let root = "berth-it-\(UUID().uuidString.prefix(8))"
        try await client.createDirectory(at: root)
        let stream = client.changes(under: root)
        let target = "\(root)/new.txt"
        let watcher = Task { () -> Bool in
            // Uploads land under a temporary name and are renamed into place, so look for
            // either form of the final name.
            for try await batch in stream {
                for change in batch {
                    switch change {
                    case .added(target), .renamed(_, target), .modified(target), .overflow: return true
                    default: continue
                    }
                }
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(300))
        try await client.write([42], to: target)
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            watcher.cancel()
        }
        let seen = try await watcher.value
        timeout.cancel()
        #expect(seen)
        try await client.removeItem(at: root, recursive: true)
    }

    @Test func reconnectsAfterTheConnectionDrops() async throws {
        let client = try makeClient(testURL!)
        _ = try await client.connect()
        client.reset()
        // Idempotent operations transparently get a new connection.
        _ = try await client.item(at: "")
        #expect(client.isConnected)
    }

    @Test func symbolicLinksRoundTrip() async throws {
        let client = try makeClient(testURL!)
        let root = "berth-it-\(UUID().uuidString.prefix(8))"
        try await client.createDirectory(at: root)
        defer { Task { try? await client.removeItem(at: root, recursive: true, ignoreMissing: true) } }
        try await client.write(Array("hi".utf8), to: "\(root)/target.txt")
        try await client.createDirectory(at: "\(root)/folder")

        let link = try await client.createSymbolicLink(at: "\(root)/link", destination: "target.txt")
        #expect(link.mightBeSymbolicLink)
        #expect(try await client.symbolicLinkDestination(at: "\(root)/link") == "target.txt")
        let dangling = "../nowhere/ünïcode file"
        try await client.createSymbolicLink(at: "\(root)/dangling", destination: dangling)
        #expect(try await client.symbolicLinkDestination(at: "\(root)/dangling") == dangling)
        try await client.createSymbolicLink(at: "\(root)/absolute", destination: "/Users/jo/Documents")
        #expect(try await client.symbolicLinkDestination(at: "\(root)/absolute") == "/Users/jo/Documents")

        // Not links: a file, a folder, and a 1067-byte file that isn't an XSym.
        #expect(try await client.symbolicLinkDestination(at: "\(root)/target.txt") == nil)
        #expect(try await client.symbolicLinkDestination(at: "\(root)/folder") == nil)
        try await client.write([UInt8](repeating: 0x41, count: 1067), to: "\(root)/lookalike")
        #expect(try await client.symbolicLinkDestination(at: "\(root)/lookalike") == nil)

        // Retargeting needs replaceExisting.
        await #expect(throws: SMBError.status(.objectNameCollision)) {
            try await client.createSymbolicLink(at: "\(root)/link", destination: "folder")
        }
        try await client.createSymbolicLink(at: "\(root)/link", destination: "folder", replaceExisting: true)
        #expect(try await client.symbolicLinkDestination(at: "\(root)/link") == "folder")

        let listing = try await client.contentsOfDirectory(at: root)
        let candidates = Set(listing.filter(\.mightBeSymbolicLink).map(\.name))
        #expect(candidates.isSuperset(of: ["link", "dangling", "absolute"]))

        // Deleting a link leaves its target alone.
        try await client.removeItem(at: "\(root)/link")
        #expect(try await client.exists("\(root)/folder"))
    }

    @Test func extendedAttributesAsEAs() async throws {
        let client = try makeClient(testURL!)
        try await extendedAttributeRoundTrip(client, expecting: .extendedAttributes)
    }

    @Test(.enabled(if: streamsURL != nil))
    func extendedAttributesAsNamedStreams() async throws {
        let client = try makeClient(streamsURL!)
        try await extendedAttributeRoundTrip(client, expecting: .namedStreams)

        // FinderInfo goes through the AFP_AfpInfo stream, which vfs_fruit validates.
        let name = "berth-it-\(UUID().uuidString.prefix(8)).txt"
        try await client.write(Array("x".utf8), to: name)
        let finderInfo = Array("TEXTttxt".utf8) + [UInt8](repeating: 0, count: 24)
        try await client.setExtendedAttributes(["com.apple.FinderInfo": finderInfo], at: name)
        #expect(try await client.extendedAttribute("com.apple.FinderInfo", at: name) == finderInfo)
        try await client.setExtendedAttributes(["com.apple.FinderInfo": nil], at: name)
        #expect(try await client.extendedAttribute("com.apple.FinderInfo", at: name) == nil)
        try await client.removeItem(at: name)
    }

    private func extendedAttributeRoundTrip(_ client: SMBClient, expecting storage: SMBAttributeStorage) async throws {
        #expect(try await client.attributeStorage() == storage)
        let root = "berth-it-\(UUID().uuidString.prefix(8))"
        try await client.createDirectory(at: root)
        defer { Task { try? await client.removeItem(at: root, recursive: true, ignoreMissing: true) } }
        let path = "\(root)/tagged.txt"
        try await client.write(Array("contents".utf8), to: path)
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try await client.setAttributes(at: path, modificationDate: stamp)
        #expect(try await client.extendedAttributes(at: path).isEmpty)

        let tags = Array("bplist00-ish tag data".utf8)
        let updated = try await client.setExtendedAttributes([
            "com.apple.metadata:_kMDItemUserTags": tags,
            "app.berth.test": [0, 1, 2, 255],
        ], at: path)
        #expect(updated.modificationDate == stamp) // metadata edits don't look like new contents
        var attributes = try await client.extendedAttributes(at: path)
        #expect(attributes["com.apple.metadata:_kMDItemUserTags"] == tags)
        #expect(attributes["app.berth.test"] == [0, 1, 2, 255])
        #expect(try await client.item(at: path).modificationDate == stamp)
        #expect(try await client.contents(of: path) == Array("contents".utf8))
        if storage == .extendedAttributes {
            let listed = try await client.contentsOfDirectory(at: root).first { $0.name == "tagged.txt" }
            #expect((listed?.eaSize ?? 0) > 0)
        }

        // Folders carry attributes too.
        try await client.setExtendedAttributes(["com.apple.metadata:_kMDItemUserTags": tags], at: root)
        #expect(try await client.extendedAttribute("com.apple.metadata:_kMDItemUserTags", at: root) == tags)

        try await client.setExtendedAttributes(["app.berth.test": nil, "missing.attribute": nil], at: path)
        attributes = try await client.extendedAttributes(at: path)
        #expect(attributes.keys.sorted() == ["com.apple.metadata:_kMDItemUserTags"])
    }

    @Test(.enabled(if: encryptedURL != nil))
    func encryptedShareRoundTrip() async throws {
        let client = try makeClient(encryptedURL!)
        let info = try await client.connect()
        #expect(info.encryption != nil)
        let name = "berth-it-\(UUID().uuidString.prefix(8)).bin"
        let (local, bytes) = try scratchFile(size: 5 << 20)
        defer { try? FileManager.default.removeItem(at: local) }
        try await client.upload(local, to: name)
        #expect(try await client.contents(of: name) == bytes)
        try await client.removeItem(at: name)
    }
}
