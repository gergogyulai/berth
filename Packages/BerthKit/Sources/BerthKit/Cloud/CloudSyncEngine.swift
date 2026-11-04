import Foundation
import Synchronization

/// Failures the File Provider extension turns into NSFileProviderError codes.
public enum CloudError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured
    case noSuchItem
    case collision
    case directoryNotEmpty
    case readOnly
    case accessDenied
    case quotaExceeded
    case notAuthenticated(String)
    case unreachable(String)
    case cancelled
    case other(String)

    public var isOffline: Bool {
        if case .unreachable = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .notConfigured: "Berth hasn't set up this location yet. Mount the share in Berth."
        case .noSuchItem: "The item no longer exists on the server."
        case .collision: "An item with that name already exists."
        case .directoryNotEmpty: "The folder is not empty."
        case .readOnly: "The share is read-only."
        case .accessDenied: "The server denied access."
        case .quotaExceeded: "The server is out of space."
        case .notAuthenticated(let message): message
        case .unreachable(let message): message
        case .cancelled: "Cancelled."
        case .other(let message): message
        }
    }

    public static func from(_ error: Error) -> CloudError {
        if let error = error as? CloudError { return error }
        if error is CancellationError { return .cancelled }
        guard let smb = error as? SMBError else { return .other("\(error)") }
        switch smb {
        case .status(let status):
            if status.isNotFound && status != .badNetworkName { return .noSuchItem }
            if status.isAuthenticationFailure || status.isPasswordExpired { return .notAuthenticated(status.message) }
            switch status {
            case .objectNameCollision: return .collision
            case .directoryNotEmpty: return .directoryNotEmpty
            case .diskFull: return .quotaExceeded
            case .mediaWriteProtected: return .readOnly
            case .accessDenied, .networkAccessDenied, .cannotDelete, .sharingViolation: return .accessDenied
            case .badNetworkName: return .unreachable(status.message)
            default: return status.invalidatesSession ? .unreachable(status.message) : .other(status.message)
            }
        case .connectionFailed, .disconnected, .timedOut:
            return .unreachable(smb.description)
        case .cancelled:
            return .cancelled
        default:
            return .other(smb.description)
        }
    }
}

/// The File Provider extension's logic for one domain: SMB operations through BerthSMB, kept
/// in step with the local index.
public final class CloudSyncEngine: Sendable {
    public let domainID: String
    public let index: CloudIndex
    private let storage: URL

    private struct State {
        var configuration: CloudDomainConfiguration?
        var client: SMBClient?
        var endpoint: CloudDomainConfiguration.Endpoint?
        var lastError: String?
    }

    private let state = Mutex(State())

    public init(domainID: String, storage: URL) throws {
        self.domainID = domainID
        self.storage = storage
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        index = try CloudIndex(url: storage.appending(path: "index.sqlite"))
        if let data = try? Data(contentsOf: configurationURL),
           let configuration = try? JSONDecoder().decode(CloudDomainConfiguration.self, from: data) {
            state.withLock { $0.configuration = configuration }
        }
    }

    private var configurationURL: URL { storage.appending(path: "configuration.json") }

    /// Scratch space for downloads and empty-file uploads.
    public var temporaryDirectory: URL { storage.appending(path: "tmp", directoryHint: .isDirectory) }

    // MARK: Configuration

    public var configuration: CloudDomainConfiguration? { state.withLock { $0.configuration } }
    public var isConfigured: Bool { configuration != nil }

    /// Stores what the app pushed. Reconnects when the endpoint or credentials changed.
    public func configure(_ configuration: CloudDomainConfiguration, password: String?) throws {
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: configurationURL, options: [.atomic])
        let previousPassword = CloudSecrets.password(for: domainID)
        let newPassword = configuration.auth == .registered ? password : nil
        if newPassword != previousPassword { CloudSecrets.setPassword(newPassword, for: domainID) }

        let stale: SMBClient? = state.withLock { s in
            var changed = s.configuration == nil || newPassword != previousPassword
            if let old = s.configuration {
                var a = old
                var b = configuration
                a.generation = .distantPast
                b.generation = .distantPast
                changed = changed || a != b
            }
            s.configuration = configuration
            guard changed else { return nil }
            let client = s.client
            s.client = nil
            s.endpoint = nil
            return client
        }
        if let stale { Task { await stale.disconnect() } }
    }

    private func client(advancingFrom failed: CloudDomainConfiguration.Endpoint? = nil) throws -> SMBClient {
        try state.withLock { s in
            guard let configuration = s.configuration else { throw CloudError.notConfigured }
            if failed == nil, let client = s.client { return client }
            let endpoints = [configuration.endpoint] + configuration.fallbacks.filter { $0 != configuration.endpoint }
            var next = configuration.endpoint
            if let failed, let index = endpoints.firstIndex(of: failed) {
                next = endpoints[(index + 1) % endpoints.count]
            }
            let password = configuration.auth == .registered ? CloudSecrets.password(for: domainID) : nil
            let client = SMBClient(configuration.clientConfiguration(endpoint: next, password: password))
            s.client = client
            s.endpoint = next
            return client
        }
    }

    /// Runs `body` with the current client, failing over to the next address once when the
    /// current one can't be reached at all.
    private func withClient<T>(_ body: (SMBClient) async throws -> T) async throws -> T {
        let client = try self.client()
        do {
            let result = try await body(client)
            state.withLock { $0.lastError = nil }
            return result
        } catch let error as SMBError {
            if case .connectionFailed = error, let endpoint = state.withLock({ $0.endpoint }),
               let alternatives = configuration?.fallbacks, !alternatives.isEmpty {
                let next = try self.client(advancingFrom: endpoint)
                do {
                    let result = try await body(next)
                    state.withLock { $0.lastError = nil }
                    return result
                } catch {
                    throw remember(error)
                }
            }
            throw remember(error)
        } catch {
            throw remember(error)
        }
    }

    private func remember(_ error: Error) -> CloudError {
        let cloud = CloudError.from(error)
        switch cloud {
        case .unreachable, .notAuthenticated, .notConfigured:
            let message = cloud.description
            state.withLock { $0.lastError = message }
        default:
            break
        }
        return cloud
    }

    public func status() -> CloudDomainStatus {
        let (configured, client, lastError) = state.withLock { ($0.configuration != nil, $0.client, $0.lastError) }
        return CloudDomainStatus(configured: configured, connected: client?.isConnected ?? false,
                                 summary: client?.connectionInfo?.summary, lastError: lastError,
                                 indexedItems: index.count, pendingChanges: index.pendingDirtyCount)
    }

    // MARK: Items

    public func item(_ id: String) async throws -> CloudIndex.Record {
        if id == CloudIndex.rootID {
            do {
                let root = try await withClient { try await $0.item(at: "") }
                return try index.updateRoot(root)
            } catch let error as CloudError where error.isOffline {
                if let cached = try index.record(id: id) { return cached }
                throw error
            }
        }
        guard let known = try index.record(id: id), let path = try index.path(of: id) else {
            throw CloudError.noSuchItem
        }
        do {
            let fresh = try await withClient { try await $0.item(at: path) }
            return try index.replace(id: id, with: fresh, parentID: known.parentID)
        } catch CloudError.noSuchItem {
            try index.remove(id: id)
            throw CloudError.noSuchItem
        } catch let error as CloudError where error.isOffline {
            return known // serve what we know while the server is away
        }
    }

    /// Lists a directory from the server and reconciles the index with it.
    @discardableResult
    public func list(_ containerID: String) async throws -> [CloudIndex.Record] {
        let path: String
        if containerID == CloudIndex.rootID {
            path = ""
            if try index.record(id: containerID) == nil { _ = try await item(containerID) }
        } else {
            guard let known = try index.path(of: containerID) else { throw CloudError.noSuchItem }
            path = known
        }
        do {
            let items = try await withClient { try await $0.contentsOfDirectory(at: path) }
            return try index.reconcile(directory: containerID, with: items)
        } catch CloudError.noSuchItem {
            if containerID != CloudIndex.rootID { try index.remove(id: containerID) }
            throw CloudError.noSuchItem
        }
    }

    /// Downloads an item's contents into a fresh file in `directory`.
    public func fetchContents(_ id: String, into directory: URL,
                              progress: SMBClient.Progress?) async throws -> (URL, CloudIndex.Record) {
        guard let known = try index.record(id: id), let path = try index.path(of: id) else {
            throw CloudError.noSuchItem
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "fetch-\(UUID().uuidString)")
        do {
            let item = try await withClient { try await $0.download(path, to: destination, progress: progress) }
            let updated = try index.replace(id: id, with: item, parentID: known.parentID)
            return (destination, updated)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if (error as? CloudError) == .noSuchItem { try? index.remove(id: id) }
            throw error
        }
    }

    public enum NewItemKind: Sendable {
        case file(contents: URL?)
        case directory
    }

    public func create(in parentID: String, name: String, kind: NewItemKind, modificationDate: Date?,
                       mayAlreadyExist: Bool) async throws -> CloudIndex.Record {
        guard configuration?.readOnly != true else { throw CloudError.readOnly }
        guard let parentPath = try index.path(of: parentID) else { throw CloudError.noSuchItem }
        let path = SMBPath.join(parentPath, name)

        switch kind {
        case .directory:
            do {
                let item = try await withClient { try await $0.createDirectory(at: path) }
                return try index.upsert(item, parentID: parentID)
            } catch CloudError.collision where mayAlreadyExist {
                let existing = try await withClient { try await $0.item(at: path) }
                guard existing.isDirectory else { throw CloudError.collision }
                return try index.upsert(existing, parentID: parentID)
            }
        case .file(let contents):
            let source = try contents ?? emptyFile()
            if mayAlreadyExist, let existing = try? await withClient({ try await $0.item(at: path) }), !existing.isDirectory,
               let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
               (attributes[.size] as? NSNumber)?.int64Value == existing.size,
               let localDate = attributes[.modificationDate] as? Date, let remoteDate = existing.modificationDate,
               abs(localDate.timeIntervalSince(remoteDate)) < 2 {
                // Re-import after a reset: the server already has this exact file.
                return try index.upsert(existing, parentID: parentID)
            }
            let item = try await withClient {
                try await $0.upload(source, to: path, replaceExisting: mayAlreadyExist, modificationDate: modificationDate)
            }
            if contents == nil { try? FileManager.default.removeItem(at: source) }
            return try index.upsert(item, parentID: parentID)
        }
    }

    /// Applies renames/moves, new contents and timestamps, in that order.
    public func modify(_ id: String, parentID newParentID: String?, name newName: String?, contents: URL?,
                       modificationDate: Date?, creationDate: Date?) async throws -> CloudIndex.Record {
        guard var record = try index.record(id: id), var path = try index.path(of: id) else {
            throw CloudError.noSuchItem
        }
        let readOnly = configuration?.readOnly == true

        if newParentID != nil || newName != nil {
            guard !readOnly else { throw CloudError.readOnly }
            let parentID = newParentID ?? record.parentID
            guard let parentPath = try index.path(of: parentID) else { throw CloudError.noSuchItem }
            let target = SMBPath.join(parentPath, newName ?? record.name)
            if target != path {
                let source = path
                let moved = try await withClient { try await $0.moveItem(at: source, to: target, replaceExisting: false) }
                record = try index.replace(id: id, with: moved, parentID: parentID)
                path = target
            }
        }

        let finalPath = path
        if let contents {
            guard !readOnly else { throw CloudError.readOnly }
            let item = try await withClient {
                try await $0.upload(contents, to: finalPath, replaceExisting: true, modificationDate: modificationDate)
            }
            record = try index.replace(id: id, with: item, parentID: record.parentID)
        } else if modificationDate != nil || creationDate != nil, !readOnly {
            let item = try await withClient {
                try await $0.setAttributes(at: finalPath, modificationDate: modificationDate, creationDate: creationDate)
            }
            record = try index.replace(id: id, with: item, parentID: record.parentID)
        }
        return record
    }

    public func delete(_ id: String, recursive: Bool) async throws {
        guard configuration?.readOnly != true else { throw CloudError.readOnly }
        guard let path = try index.path(of: id) else { return } // already gone
        try await withClient { try await $0.removeItem(at: path, recursive: recursive, ignoreMissing: true) }
        try index.remove(id: id)
    }

    private func emptyFile() throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory.appending(path: "empty-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CloudError.other("Could not create a temporary file.")
        }
        return url
    }

    // MARK: Change tracking

    public func markDirty(_ paths: [String], recursive: Bool) {
        for path in paths { try? index.markDirty(path, recursive: recursive) }
    }

    /// Re-lists directories flagged by the app's change notifications, plus listed directories
    /// that haven't been checked for `rescanInterval`, so remote changes reach the change log.
    public func refresh(rescanInterval: TimeInterval = 600, maxDirectories: Int = 48) async {
        var targets: [String] = []
        var seen = Set<String>()
        func add(_ id: String) {
            if seen.insert(id).inserted { targets.append(id) }
        }
        for mark in (try? index.takeDirty()) ?? [] {
            guard let id = try? index.id(forPath: mark.path) else { continue }
            if mark.recursive {
                for directory in (try? index.listedDirectories(under: id)) ?? [] { add(directory) }
            } else if (try? index.isListed(id)) == true {
                add(id)
            }
        }
        let cutoff = Date().addingTimeInterval(-rescanInterval)
        for id in (try? index.listedDirectories(scannedBefore: cutoff, limit: maxDirectories)) ?? [] { add(id) }

        let batch = Array(targets.prefix(maxDirectories))
        // Requeue the rest for the next round.
        for id in targets.dropFirst(maxDirectories) {
            if let path = try? index.path(of: id) { try? index.markDirty(path, recursive: false) }
        }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for id in batch {
                if running >= 4 {
                    _ = await group.next()
                    running -= 1
                }
                group.addTask { _ = try? await self.list(id) }
                running += 1
            }
        }
        try? index.pruneChanges()
    }
}
