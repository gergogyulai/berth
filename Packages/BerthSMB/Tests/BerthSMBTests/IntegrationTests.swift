import Foundation
import Testing
@testable import BerthSMB

/// Runs against a real server when BERTH_SMB_TEST_URL is set, e.g.
/// `BERTH_SMB_TEST_URL='smb://user:pass@127.0.0.1:4450/share' swift test`.
/// BERTH_SMB_TEST_ENCRYPTED_URL can point at a share with `smb encrypt = required`.
private let testURL = ProcessInfo.processInfo.environment["BERTH_SMB_TEST_URL"]
private let encryptedURL = ProcessInfo.processInfo.environment["BERTH_SMB_TEST_ENCRYPTED_URL"]

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
