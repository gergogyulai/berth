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

    /// Worth retrying later rather than working around now.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .notAuthenticated, .notConfigured, .cancelled, .noSuchItem: true
        default: false
        }
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
        /// How the current client's share stores extended attributes, once known.
        var storage: SMBAttributeStorage?
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
            s.storage = nil
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
            s.storage = nil
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
            let record = try index.replace(id: id, with: fresh, parentID: known.parentID)
            return await refreshExtras([(record, fresh)]).first ?? record
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
            let records = try index.reconcile(directory: containerID, with: items)
            var byName: [String: SMBItem] = [:]
            for item in items { byName[item.name] = item }
            return await refreshExtras(records.compactMap { record in byName[record.name].map { (record, $0) } })
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
        if let target = known.symlinkTarget {
            // A link's contents are its target; there's nothing to download.
            do {
                try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            } catch {
                throw CloudError.other("Could not create the symbolic link: \(error.localizedDescription)")
            }
            return (destination, known)
        }
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
        case symbolicLink(target: String)
    }

    /// Extended attributes and tags for a new or modified item.
    public struct Metadata: Sendable, Equatable {
        public var extendedAttributes: [String: Data]
        public var tagData: Data?

        public init(extendedAttributes: [String: Data] = [:], tagData: Data? = nil) {
            self.extendedAttributes = extendedAttributes
            self.tagData = tagData
        }

        public var isEmpty: Bool { extendedAttributes.isEmpty && (tagData?.isEmpty ?? true) }
    }

    public func create(in parentID: String, name: String, kind: NewItemKind, modificationDate: Date?,
                       metadata: Metadata = Metadata(), mayAlreadyExist: Bool) async throws -> CloudIndex.Record {
        let record = try await createItem(in: parentID, name: name, kind: kind, modificationDate: modificationDate,
                                          mayAlreadyExist: mayAlreadyExist)
        guard !metadata.isEmpty, !record.isSymbolicLink else { return record }
        return try await applyMetadata(metadata, to: record, replacingServerState: !mayAlreadyExist)
    }

    private func createItem(in parentID: String, name: String, kind: NewItemKind, modificationDate: Date?,
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
        case .symbolicLink(let target):
            let item: SMBItem
            do {
                item = try await withClient { try await $0.createSymbolicLink(at: path, destination: target) }
            } catch CloudError.collision where mayAlreadyExist {
                let existing = try await withClient { client -> (SMBItem, String?) in
                    let item = try await client.item(at: path)
                    guard item.mightBeSymbolicLink else { return (item, nil) }
                    return (item, try await client.symbolicLinkDestination(at: path))
                }
                guard existing.1 == target else { throw CloudError.collision }
                item = existing.0
            }
            let record = try index.upsert(item, parentID: parentID)
            return try index.setExtras(id: record.id, symlinkTarget: target, extendedAttributes: [:], tagData: nil,
                                       stamp: CloudIndex.ExtrasStamp(item)) ?? record
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

    /// Applies renames/moves, new contents (or a new link target), timestamps and metadata, in
    /// that order. nil leaves a field as it is.
    public func modify(_ id: String, parentID newParentID: String?, name newName: String?, contents: URL?,
                       symlinkTarget: String? = nil, modificationDate: Date?, creationDate: Date?,
                       extendedAttributes: [String: Data]? = nil, tagData: Data?? = nil) async throws -> CloudIndex.Record {
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
        var replacedFile = false
        if let symlinkTarget, record.isSymbolicLink, symlinkTarget != record.symlinkTarget {
            guard !readOnly else { throw CloudError.readOnly }
            let item = try await withClient {
                try await $0.createSymbolicLink(at: finalPath, destination: symlinkTarget, replaceExisting: true)
            }
            record = try index.replace(id: id, with: item, parentID: record.parentID)
            record = try index.setExtras(id: id, symlinkTarget: symlinkTarget, extendedAttributes: [:], tagData: nil,
                                         stamp: CloudIndex.ExtrasStamp(item)) ?? record
        } else if let contents, !record.isSymbolicLink {
            guard !readOnly else { throw CloudError.readOnly }
            let item = try await withClient {
                try await $0.upload(contents, to: finalPath, replaceExisting: true, modificationDate: modificationDate)
            }
            record = try index.replace(id: id, with: item, parentID: record.parentID)
            replacedFile = true
        } else if modificationDate != nil || creationDate != nil, !readOnly {
            let item = try await withClient {
                try await $0.setAttributes(at: finalPath, modificationDate: modificationDate, creationDate: creationDate)
            }
            record = try index.replace(id: id, with: item, parentID: record.parentID)
        }

        if record.isSymbolicLink { return record }
        var metadata = Metadata(extendedAttributes: record.extendedAttributes, tagData: record.tagData)
        if let extendedAttributes { metadata.extendedAttributes = extendedAttributes }
        if let tagData { metadata.tagData = tagData }
        let changed = metadata != Metadata(extendedAttributes: record.extendedAttributes, tagData: record.tagData)
        // An upload replaces the server file, and its streams or EAs with it: write them again.
        if changed || (replacedFile && !metadata.isEmpty) {
            record = try await applyMetadata(metadata, to: record, replacingServerState: replacedFile)
        }
        return record
    }

    // MARK: Links, extended attributes and tags

    /// Where Finder's own SMB client keeps tags, so a Mac with the share mounted in Finder sees the
    /// same ones.
    static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"
    /// Where File Provider tag data goes when it isn't in the `_kMDItemUserTags` format.
    static let opaqueTagAttribute = "app.berth.tagData"
    /// Attributes File Provider handles itself (tags, Finder info, resource fork, dates) or that
    /// shouldn't travel between Macs.
    static let unsyncedAttributes: Set<String> = [
        tagAttribute, opaqueTagAttribute, "com.apple.FinderInfo", "com.apple.ResourceFork", "com.apple.quarantine",
        "com.apple.lastuseddate#PS", "com.apple.macl", "com.apple.provenance", "Zone.Identifier",
    ]
    /// File Provider syncs about 32 KiB of extended attributes per item.
    static let attributeBudget = 32 * 1024

    static func isSyncable(_ name: String) -> Bool {
        !name.isEmpty && !unsyncedAttributes.contains(name) && !name.hasPrefix("AFP_")
    }

    /// The server attributes as File Provider's extended attributes and tag data.
    static func metadata(fromServer attributes: [String: [UInt8]]) -> Metadata {
        var out = Metadata()
        var budget = attributeBudget
        for (name, value) in attributes.sorted(by: { $0.key < $1.key }) where isSyncable(name) {
            guard value.count <= budget else { continue }
            budget -= value.count
            out.extendedAttributes[name] = Data(value)
        }
        if let tags = attributes[tagAttribute] ?? attributes[opaqueTagAttribute], !tags.isEmpty {
            out.tagData = Data(tags)
        }
        return out
    }

    /// Tag data in the `_kMDItemUserTags` format: a property list array of strings.
    static func isUserTagsPlist(_ data: Data) -> Bool {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String]
    }

    /// The writes that turn the server's `current` attributes into `desired`, touching only the
    /// attributes this engine manages.
    static func changes(from current: [String: [UInt8]], to desired: Metadata) -> [String: [UInt8]?] {
        var changes: [String: [UInt8]?] = [:]
        for (name, value) in desired.extendedAttributes where isSyncable(name) {
            let bytes = [UInt8](value)
            if current[name] != bytes { changes[name] = .some(bytes) }
        }
        for name in current.keys where isSyncable(name) && desired.extendedAttributes[name] == nil {
            changes[name] = .some(nil)
        }
        let tags = desired.tagData.flatMap { $0.isEmpty ? nil : [UInt8]($0) }
        if let tags, isUserTagsPlist(Data(tags)) {
            if current[tagAttribute] != tags { changes[tagAttribute] = .some(tags) }
            if current[opaqueTagAttribute] != nil { changes[opaqueTagAttribute] = .some(nil) }
        } else if let tags {
            // Unknown format: keep it to ourselves rather than clobber Finder's tags.
            if current[opaqueTagAttribute] != tags { changes[opaqueTagAttribute] = .some(tags) }
        } else {
            if current[tagAttribute] != nil { changes[tagAttribute] = .some(nil) }
            if current[opaqueTagAttribute] != nil { changes[opaqueTagAttribute] = .some(nil) }
        }
        return changes
    }

    private func attributeStorage(_ client: SMBClient) async -> SMBAttributeStorage {
        if let known = state.withLock({ $0.client === client ? $0.storage : nil }) { return known }
        guard let storage = try? await client.attributeStorage() else { return .none }
        state.withLock { s in if s.client === client { s.storage = storage } }
        return storage
    }

    /// Writes extended attributes and tags to the server (or, where it can't store them, just to
    /// the index, so they stay on this Mac) and records the result.
    private func applyMetadata(_ metadata: Metadata, to record: CloudIndex.Record,
                               replacingServerState: Bool) async throws -> CloudIndex.Record {
        let keepLocally = {
            try self.index.setExtras(id: record.id, symlinkTarget: record.symlinkTarget,
                                     extendedAttributes: metadata.extendedAttributes, tagData: metadata.tagData,
                                     stamp: nil) ?? record
        }
        guard configuration?.readOnly != true, let path = try index.path(of: record.id) else { return try keepLocally() }
        do {
            let result: (SMBItem, Metadata)? = try await withClient { client in
                guard await self.attributeStorage(client) != .none else { return nil }
                var current: [String: [UInt8]] = [:]
                if !replacingServerState { current = try await client.extendedAttributes(at: path) }
                let changes = Self.changes(from: current, to: metadata)
                let item: SMBItem
                if changes.isEmpty {
                    item = try await client.item(at: path)
                } else {
                    item = try await client.setExtendedAttributes(changes, at: path)
                }
                var stored = current
                for (name, value) in changes { stored[name] = value }
                return (item, Self.metadata(fromServer: stored))
            }
            guard let result else { return try keepLocally() }
            let (item, stored) = result
            let updated = try index.replace(id: record.id, with: item, parentID: record.parentID)
            return try index.setExtras(id: record.id, symlinkTarget: nil, extendedAttributes: stored.extendedAttributes,
                                       tagData: stored.tagData, stamp: CloudIndex.ExtrasStamp(item)) ?? updated
        } catch let error as CloudError where error.isTransient {
            throw error
        } catch {
            // The server refused an attribute (a name it can't store, a size limit…). Failing the
            // whole change would make the system retry forever; keep the metadata on this Mac.
            return try keepLocally()
        }
    }

    /// Reads link targets and extended attributes for records whose server state changed since
    /// they were last read. Failures leave the old values in place.
    private func refreshExtras(_ pairs: [(CloudIndex.Record, SMBItem)]) async -> [CloudIndex.Record] {
        let stale = pairs.enumerated().filter { _, pair in
            let (record, item) = pair
            if record.isRoot { return false }
            guard let stamp = record.extrasStamp else { return true }
            return stamp.isStale(for: item)
        }
        guard !stale.isEmpty, let client = try? self.client() else { return pairs.map(\.0) }
        let storage = await attributeStorage(client)
        var results = pairs.map(\.0)
        await withTaskGroup(of: (Int, CloudIndex.Record?).self) { group in
            var running = 0
            for (offset, pair) in stale {
                if running >= 32 {
                    if let next = await group.next(), let record = next.1 { results[next.0] = record }
                    running -= 1
                }
                group.addTask {
                    (offset, await self.readExtras(record: pair.0, item: pair.1, storage: storage, client: client))
                }
                running += 1
            }
            for await (index, record) in group {
                if let record { results[index] = record }
            }
        }
        return results
    }

    private func readExtras(record: CloudIndex.Record, item: SMBItem, storage: SMBAttributeStorage,
                            client: SMBClient) async -> CloudIndex.Record? {
        do {
            let path = item.path
            var target: String?
            if item.mightBeSymbolicLink { target = try await client.symbolicLinkDestination(at: path) }
            var metadata = Metadata(extendedAttributes: record.extendedAttributes, tagData: record.tagData)
            if target != nil {
                metadata = Metadata()
            } else if storage == .extendedAttributes && item.eaSize == 0 {
                metadata = Metadata() // no EAs at all, and the listing said so for free
            } else if storage != .none {
                let attributes = try await client.extendedAttributes(at: path)
                metadata = Self.metadata(fromServer: attributes)
            }
            return try index.setExtras(id: record.id, symlinkTarget: target, extendedAttributes: metadata.extendedAttributes,
                                       tagData: metadata.tagData, stamp: CloudIndex.ExtrasStamp(item))
        } catch {
            return nil
        }
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
