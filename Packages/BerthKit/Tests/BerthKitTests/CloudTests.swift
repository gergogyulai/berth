import Foundation
import Testing
@testable import BerthKit

private func temporaryIndex() throws -> (CloudIndex, URL) {
    let url = FileManager.default.temporaryDirectory.appending(path: "berth-index-\(UUID().uuidString)/index.sqlite")
    return (try CloudIndex(url: url), url.deletingLastPathComponent())
}

private func file(_ path: String, id: UInt64, size: Int64 = 1, mtime: UInt64 = 1) -> SMBItem {
    SMBItem(path: path, fileID: id, isDirectory: false, size: size, lastWriteTime: mtime, changeTime: mtime)
}

private func folder(_ path: String, id: UInt64) -> SMBItem {
    SMBItem(path: path, fileID: id, isDirectory: true)
}

@Suite struct CloudModelTests {
    @Test func backendDefaultsToSystemAndRoundTrips() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","shareName":"x"}"#
        let old = try JSONDecoder().decode(Share.self, from: Data(json.utf8))
        #expect(old.backend == .system)
        #expect(old.cloud == CloudOptions())

        var share = Share(shareName: "media", backend: .cloud, cloud: CloudOptions(requireEncryption: true))
        share.displayName = "NAS"
        let decoded = try JSONDecoder().decode(Share.self, from: JSONEncoder().encode(share))
        #expect(decoded.backend == .cloud)
        #expect(decoded.cloud.requireEncryption)
    }

    @Test func smbErrorsMapOntoMountErrorKinds() {
        #expect(MountError.from(SMBError.status(.logonFailure)).kind == .authentication)
        #expect(MountError.from(SMBError.status(.passwordMustChange)).kind == .passwordExpired)
        #expect(MountError.from(SMBError.status(.badNetworkName)).kind == .shareNotFound)
        #expect(MountError.from(SMBError.connectionFailed(code: ECONNREFUSED, message: "refused")).kind == .hostUnreachable)
        #expect(MountError.from(SMBError.connectionFailed(code: ETIMEDOUT, message: "slow")).kind == .timedOut)
        #expect(MountError.from(SMBError.timedOut).kind == .timedOut)
        #expect(MountError.from(SMBError.unsupported("CCM")).kind == .invalidConfiguration)
    }

    @Test func smbErrorsMapOntoCloudErrors() {
        #expect(CloudError.from(SMBError.status(.objectNameNotFound)) == .noSuchItem)
        #expect(CloudError.from(SMBError.status(.objectNameCollision)) == .collision)
        #expect(CloudError.from(SMBError.status(.directoryNotEmpty)) == .directoryNotEmpty)
        #expect(CloudError.from(SMBError.disconnected("x")).isOffline)
        #expect(CloudError.from(CancellationError()) == .cancelled)
    }

    @MainActor @Test func domainConfigurationBuildsClientConfiguration() throws {
        let share = Share(addresses: [ServerAddress(host: "nas.local"), ServerAddress(host: "nas.tail.ts.net", port: 4450)],
                          shareName: "media", auth: .registered, username: "jo", domain: "HOME", backend: .cloud)
        let configuration = CloudVolumes.configuration(for: share, address: share.addresses[1], fallbacks: share.addresses)
        #expect(configuration.endpoint == .init(host: "nas.tail.ts.net", port: 4450))
        #expect(configuration.fallbacks == [.init(host: "nas.local", port: 445)])
        #expect(configuration.tuning == .wan) // Tailscale link, no preset
        let decoded = try JSONDecoder().decode(CloudDomainConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded == configuration)
        let client = configuration.clientConfiguration(endpoint: configuration.endpoint, password: "pw")
        #expect(client.credentials == .user(name: "jo", password: "pw", domain: "HOME"))
        #expect(client.port == 4450)
    }
}

@Suite struct CloudIndexTests {
    @Test func listingCreatesRecordsAndLogsChanges() throws {
        let (index, dir) = try temporaryIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        try index.updateRoot(folder("", id: 1))
        let records = try index.reconcile(directory: CloudIndex.rootID, with: [
            folder("Photos", id: 10), file("a.txt", id: 11), file(".berth-upload-1234", id: 12),
        ])
        #expect(records.map(\.name).sorted() == ["Photos", "a.txt"]) // temp uploads are hidden
        #expect(try index.path(of: records.first { $0.name == "Photos" }!.id) == "Photos")
        let changes = try index.changes(since: 0)
        #expect(changes.updated.count == 3) // root + 2
        #expect(!changes.moreComing)

        // Listing the same thing again changes nothing.
        let anchor = index.currentAnchor
        try index.reconcile(directory: CloudIndex.rootID, with: [folder("Photos", id: 10), file("a.txt", id: 11)])
        #expect(index.currentAnchor == anchor)
    }

    @Test func identitySurvivesRenamesSafeSavesAndMoves() throws {
        let (index, dir) = try temporaryIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        try index.updateRoot(folder("", id: 1))
        let first = try index.reconcile(directory: CloudIndex.rootID, with: [folder("Docs", id: 2), file("report.txt", id: 3)])
        let docs = first.first { $0.name == "Docs" }!.id
        let report = first.first { $0.name == "report.txt" }!.id

        // Renamed on the server: same file id, new name → same identifier.
        let renamed = try index.reconcile(directory: CloudIndex.rootID, with: [folder("Docs", id: 2), file("final.txt", id: 3)])
        #expect(renamed.first { $0.name == "final.txt" }?.id == report)

        // Safe-saved by another client: new file id, same name → still the same identifier.
        let saved = try index.reconcile(directory: CloudIndex.rootID, with: [folder("Docs", id: 2), file("final.txt", id: 99, size: 5)])
        #expect(saved.first { $0.name == "final.txt" }?.id == report)
        #expect(try index.record(id: report)?.fileID == 99)

        // Moved into Docs: the root listing no longer has it, Docs does → same identifier, no deletion.
        try index.reconcile(directory: docs, with: [file("Docs/final.txt", id: 99, size: 5)])
        try index.reconcile(directory: CloudIndex.rootID, with: [folder("Docs", id: 2)])
        #expect(try index.path(of: report) == "Docs/final.txt")
        #expect(try index.changes(since: 0).deleted.isEmpty)
    }

    @Test func deletionsRemoveSubtreesAndAnchorsAdvance() throws {
        let (index, dir) = try temporaryIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        try index.updateRoot(folder("", id: 1))
        let top = try index.reconcile(directory: CloudIndex.rootID, with: [folder("A", id: 2)])
        let a = top[0].id
        let inside = try index.reconcile(directory: a, with: [file("A/x", id: 3), file("A/y", id: 4)])
        let anchor = index.currentAnchor

        try index.reconcile(directory: CloudIndex.rootID, with: [])
        #expect(try index.record(id: a) == nil)
        #expect(try index.record(id: inside[0].id) == nil)
        let changes = try index.changes(since: anchor)
        #expect(Set(changes.deleted) == Set([a] + inside.map(\.id)))
        #expect(changes.anchor > anchor)

        try index.pruneChanges(keeping: 0)
        #expect(throws: CloudIndex.IndexError.self) { try index.changes(since: 0) }
    }

    @Test func dirtyMarksAndPathLookups() throws {
        let (index, dir) = try temporaryIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        try index.updateRoot(folder("", id: 1))
        let top = try index.reconcile(directory: CloudIndex.rootID, with: [folder("Média", id: 2)])
        #expect(try index.id(forPath: "média") == top[0].id) // case-insensitive, like the server
        #expect(try index.isListed(CloudIndex.rootID))
        #expect(try !index.isListed(top[0].id))

        try index.markDirty("Média", recursive: false)
        try index.markDirty("Média", recursive: true)
        try index.markDirty("", recursive: false)
        let marks = try index.takeDirty()
        #expect(marks.count == 2)
        #expect(marks.first { $0.path == "Média" }?.recursive == true)
        #expect(try index.takeDirty().isEmpty)
    }
}
