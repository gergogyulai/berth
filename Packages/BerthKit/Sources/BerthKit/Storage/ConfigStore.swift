import Foundation
import os

/// Loads, saves and watches `config.json`.
///
/// The file normally lives in Application Support. With iCloud sync on, it moves to
/// `iCloud Drive/Berth/config.json` and changes from other Macs are picked up live. Passwords are
/// never part of the file.
@MainActor
@Observable
public final class ConfigStore {
    public private(set) var config: Configuration
    public private(set) var lastError: String?
    public private(set) var syncEnabled: Bool

    /// Called after the configuration was replaced by an external change (another Mac, an import).
    @ObservationIgnored public var onExternalChange: ((Configuration) -> Void)?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var lastWrittenData: Data?
    @ObservationIgnored private let log = Logger(subsystem: "app.berth", category: "config")
    @ObservationIgnored private let defaults: UserDefaults

    nonisolated public static let syncDefaultsKey = "SyncConfigurationViaICloudDrive"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.syncEnabled = defaults.bool(forKey: Self.syncDefaultsKey)
        self.config = Configuration()
        load()
        startWatching()
    }

    // MARK: Locations

    nonisolated public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Berth", directoryHint: .isDirectory)
    }

    nonisolated public static var localFileURL: URL { supportDirectory.appending(path: "config.json") }

    nonisolated public static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    nonisolated public static var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDriveRoot.path)
    }

    nonisolated public static var iCloudFileURL: URL {
        iCloudDriveRoot.appending(path: "Berth/config.json")
    }

    public var fileURL: URL { syncEnabled ? Self.iCloudFileURL : Self.localFileURL }

    // MARK: Mutation

    public func update(_ body: (inout Configuration) -> Void) {
        var copy = config
        body(&copy)
        guard copy != config else { return }
        config = copy
        scheduleSave()
    }

    public func replace(with configuration: Configuration) {
        config = configuration
        scheduleSave()
    }

    public func upsert(_ share: Share) {
        update { config in
            if let idx = config.shares.firstIndex(where: { $0.id == share.id }) {
                config.shares[idx] = share
            } else {
                config.shares.append(share)
            }
        }
    }

    public func removeShare(id: UUID) {
        update { $0.shares.removeAll { $0.id == id } }
        Keychain.deletePassword(for: id)
    }

    public func moveShares(from source: IndexSet, to destination: Int) {
        update { config in
            let moving = source.map { config.shares[$0] }
            let insertion = destination - source.filter { $0 < destination }.count
            for index in source.sorted(by: >) { config.shares.remove(at: index) }
            config.shares.insert(contentsOf: moving, at: min(insertion, config.shares.count))
        }
    }

    // MARK: Sync

    public func setSyncEnabled(_ enabled: Bool) throws {
        guard enabled != syncEnabled else { return }
        if enabled {
            guard Self.iCloudDriveAvailable else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "iCloud Drive is not enabled on this Mac."])
            }
            let fm = FileManager.default
            try fm.createDirectory(at: Self.iCloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: Self.iCloudFileURL.path),
               let remote = try? Self.decode(Data(contentsOf: Self.iCloudFileURL)) {
                // Another Mac already syncs: merge — remote wins for shares it knows, keep local-only ones.
                config = Self.merge(local: config, remote: remote)
            }
        }
        syncEnabled = enabled
        defaults.set(enabled, forKey: Self.syncDefaultsKey)
        saveNow()
        startWatching()
    }

    static func merge(local: Configuration, remote: Configuration) -> Configuration {
        var result = remote
        for share in local.shares where !remote.shares.contains(where: { $0.id == share.id }) {
            result.shares.append(share)
        }
        for group in local.groups where !remote.groups.contains(where: { $0.id == group.id }) {
            result.groups.append(group)
        }
        return result
    }

    // MARK: Import / Export

    public func exportData() throws -> Data {
        try Self.encoder.encode(config)
    }

    public enum ImportMode { case merge, replace }

    @discardableResult
    public func importData(_ data: Data, mode: ImportMode) throws -> Int {
        let incoming = try Self.decode(data)
        switch mode {
        case .replace:
            replace(with: incoming)
            return incoming.shares.count
        case .merge:
            var added = 0
            update { config in
                for group in incoming.groups where !config.groups.contains(where: { $0.id == group.id }) {
                    config.groups.append(group)
                }
                for share in incoming.shares {
                    if let idx = config.shares.firstIndex(where: { $0.id == share.id }) {
                        config.shares[idx] = share
                    } else {
                        config.shares.append(share)
                        added += 1
                    }
                }
                config.homeNetworks.ssids = (config.homeNetworks.ssids + incoming.homeNetworks.ssids).uniqued()
            }
            return added
        }
    }

    // MARK: Persistence

    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    nonisolated static func decode(_ data: Data) throws -> Configuration {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Configuration.self, from: data)
    }

    private func load() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // iCloud sync on but the file is not downloaded yet: fall back to the local copy.
            if syncEnabled, let local = try? Self.decode(Data(contentsOf: Self.localFileURL)) { config = local }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            config = try Self.decode(data)
            lastWrittenData = data
            lastError = nil
        } catch {
            lastError = "Could not read the configuration: \(error.localizedDescription)"
            log.error("Config load failed: \(error.localizedDescription, privacy: .public)")
            // Keep the broken file for inspection instead of silently overwriting it.
            let broken = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: broken)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        do {
            let data = try Self.encoder.encode(config)
            let urls = syncEnabled ? [Self.iCloudFileURL, Self.localFileURL] : [Self.localFileURL]
            for url in urls {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            }
            lastWrittenData = data
            lastError = nil
        } catch {
            lastError = "Could not save the configuration: \(error.localizedDescription)"
            log.error("Config save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startWatching() {
        watcher = nil
        guard syncEnabled else { return }
        let dir = Self.iCloudFileURL.deletingLastPathComponent()
        watcher = DirectoryWatcher(url: dir) { [weak self] in
            Task { @MainActor in self?.externalFileChanged() }
        }
    }

    private func externalFileChanged() {
        guard let data = try? Data(contentsOf: fileURL), data != lastWrittenData,
              let incoming = try? Self.decode(data), incoming != config else { return }
        log.info("Configuration changed externally; reloading")
        lastWrittenData = data
        config = incoming
        try? data.write(to: Self.localFileURL, options: .atomic)
        onExternalChange?(incoming)
    }
}

/// Watches a directory for writes (atomic file replacement shows up as a directory change).
final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .global(qos: .utility))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
