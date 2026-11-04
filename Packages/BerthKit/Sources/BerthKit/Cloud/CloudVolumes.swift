import FileProvider
import Foundation
import os

/// App-side manager for shares that use the cloud backend.
///
/// Each such share is a File Provider domain ("Berth Cloud"): Finder shows it under Locations
/// like iCloud Drive, with on-demand downloads, and the BerthCloud extension talks to the server
/// with BerthSMB. The app keeps its own small SMB session per share for health probes and for a
/// CHANGE_NOTIFY watch that tells the extension which folders changed on the server.
@MainActor
public final class CloudVolumes {
    public static let shared = CloudVolumes()

    private final class Session {
        let shareID: UUID
        let client: SMBClient
        var watch: Task<Void, Never>?
        var flush: Task<Void, Never>?
        var dirty: Set<String> = []
        var needsFullRescan = false

        init(shareID: UUID, client: SMBClient) {
            self.shareID = shareID
            self.client = client
        }

        func stop() {
            watch?.cancel()
            flush?.cancel()
            let client = client
            Task { await client.disconnect() }
        }
    }

    private var sessions: [UUID: Session] = [:]
    private var controls: [UUID: NSXPCConnection] = [:]
    private let logger = Logger(subsystem: "app.berth", category: "cloud")

    /// Hook for the coordinator's event log.
    public var log: ((EventLog.Entry.Level, String, UUID) -> Void)?

    /// Whether this build can create cloud volumes at all.
    public static var isAvailable: Bool { BerthCloud.isExtensionEmbedded }

    public static let unavailableMessage = "This copy of Berth doesn't include the Berth Cloud extension. Build it with a development team (see the README), or use the macOS SMB backend."

    // MARK: Mounting

    /// Signs in with BerthSMB (proving server, share and credentials exactly like a mount would),
    /// then adds or reconnects the File Provider domain and returns its folder.
    public func mount(_ share: Share, address: ServerAddress, fallbacks: [ServerAddress], password: String?,
                      timeout: Duration) async throws(MountError) -> String {
        guard Self.isAvailable else {
            throw MountError(kind: .invalidConfiguration, message: Self.unavailableMessage)
        }
        let configuration = Self.configuration(for: share, address: address, fallbacks: fallbacks)
        var clientConfiguration = configuration.clientConfiguration(endpoint: configuration.endpoint, password: password)
        clientConfiguration.connectTimeout = timeout

        // 1. A real login first: wrong passwords and missing shares fail here, mapped to the same
        //    errors NetFS produces, so the coordinator's state machine needs no special cases.
        let client = SMBClient(clientConfiguration)
        let info: SMBConnectionInfo
        do {
            info = try await client.connect()
        } catch let error as SMBError {
            throw MountError.from(error)
        } catch {
            throw MountError(kind: .other, message: error.localizedDescription)
        }

        // 2. The domain.
        let domain = Self.domain(for: share)
        let path: String
        do {
            try await Self.call { NSFileProviderManager.add(domain, completionHandler: $0) }
            guard let manager = NSFileProviderManager(for: domain) else {
                throw MountError(kind: .other, message: "macOS did not create the cloud location.")
            }
            try? await Self.call { manager.reconnect(completionHandler: $0) }
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                manager.getUserVisibleURL(for: .rootContainer) { url, error in
                    if let url { continuation.resume(returning: url) } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                    }
                }
            }
            path = url.path

            // 3. Hand the extension its configuration and credentials.
            do {
                try await push(configuration, password: password, to: share.id, rootURL: url)
            } catch {
                log?(.warning, "Could not configure the cloud extension yet: \(error.localizedDescription)", share.id)
            }
            try? await Self.call { manager.signalEnumerator(for: .rootContainer, completionHandler: $0) }
            try? await Self.call { manager.signalEnumerator(for: .workingSet, completionHandler: $0) }
        } catch let error as MountError {
            await client.disconnect()
            throw error
        } catch {
            await client.disconnect()
            throw MountError(kind: .other, message: "Could not set up the cloud location: \(error.localizedDescription)")
        }

        // 4. Our own session: probes and change notifications.
        sessions[share.id]?.stop()
        let session = Session(shareID: share.id, client: client)
        sessions[share.id] = session
        startWatching(session, domain: domain)
        log?(.debug, "Berth SMB: \(info.summary)", share.id)
        return path
    }

    /// Disconnects the location (it stays in Finder, greyed out, with its downloaded files).
    public func unmount(_ shareID: UUID, reason: String = "Disconnected in Berth") async throws(MountError) {
        sessions.removeValue(forKey: shareID)?.stop()
        controls.removeValue(forKey: shareID)?.invalidate()
        guard let domain = await Self.existingDomain(shareID), let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await Self.call { manager.disconnect(reason: reason, options: [], completionHandler: $0) }
        } catch {
            throw MountError(kind: .other, message: "Could not disconnect the cloud location: \(error.localizedDescription)")
        }
    }

    /// Removes the location and its local data (share deleted, or switched to the macOS backend).
    public func removeDomain(_ shareID: UUID) async {
        sessions.removeValue(forKey: shareID)?.stop()
        controls.removeValue(forKey: shareID)?.invalidate()
        guard let domain = await Self.existingDomain(shareID) else { return }
        do {
            try await Self.call { NSFileProviderManager.remove(domain, completionHandler: $0) }
            log?(.info, "Removed the cloud location", shareID)
        } catch {
            log?(.warning, "Could not remove the cloud location: \(error.localizedDescription)", shareID)
        }
    }

    /// Drops the app's SMB session (after a network change); the domain stays as it is.
    public func dropSession(_ shareID: UUID) {
        sessions.removeValue(forKey: shareID)?.stop()
    }

    /// The location's folder, when its domain exists and is connected.
    public func connectedPath(_ shareID: UUID) async -> String? {
        guard let domain = await Self.existingDomain(shareID), !domain.isDisconnected,
              let manager = NSFileProviderManager(for: domain) else { return nil }
        let url: URL? = try? await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                }
            }
        }
        return url?.path
    }

    /// Liveness of a mounted cloud share: an SMB ECHO on the app's session, plus a check that the
    /// user didn't remove the location from Finder.
    public func probe(_ shareID: UUID, timeout: Duration) async -> FileSystemProbe.Result {
        guard await Self.existingDomain(shareID) != nil else { return .notMounted }
        guard let client = sessions[shareID]?.client else { return .error(ENOTCONN) }
        let result: Result<Duration, Error>? = await withTaskGroup(of: Result<Duration, Error>?.self) { group in
            group.addTask {
                do { return .success(try await client.echo()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch result {
        case .success(let latency)?: return .alive(latency: latency)
        case .failure(let error)?:
            if case SMBError.timedOut? = error as? SMBError { return .timedOut }
            return .error((error as? SMBError).map { MountError.from($0).code } ?? EIO)
        case nil: return .timedOut
        }
    }

    public func connectionInfo(_ shareID: UUID) -> SMBConnectionInfo? {
        sessions[shareID]?.client.connectionInfo
    }

    /// The app's SMB client for a mounted cloud share (speed tests, diagnostics).
    public func client(_ shareID: UUID) -> SMBClient? { sessions[shareID]?.client }

    /// What the extension reports about the domain.
    public func extensionStatus(_ shareID: UUID) async -> CloudDomainStatus? {
        guard let proxy = await control(for: shareID) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            proxy.status { continuation.resume(returning: $0) }
        }
        return data.flatMap { try? JSONDecoder().decode(CloudDomainStatus.self, from: $0) }
    }

    // MARK: Change notifications

    private func startWatching(_ session: Session, domain: NSFileProviderDomain) {
        session.watch = Task { [weak self, weak session] in
            var backoff: Duration = .seconds(2)
            while !Task.isCancelled, let client = session?.client {
                do {
                    for try await batch in client.changes(under: "", recursive: true) {
                        backoff = .seconds(2)
                        guard let session else { return }
                        self?.note(batch, session: session, domain: domain)
                    }
                } catch {
                    // Dropped connection, server restart…: fall through and retry.
                }
                guard !Task.isCancelled, let session else { return }
                // Events may have been missed while the watch was down.
                self?.note([.overflow], session: session, domain: domain)
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }

    private func note(_ batch: [SMBChange], session: Session, domain: NSFileProviderDomain) {
        for change in batch {
            if change == .overflow { session.needsFullRescan = true }
            for directory in change.affectedDirectories { session.dirty.insert(directory) }
            if case .added(let path) = change { session.dirty.insert(path) }
            if case .renamed(_, let to) = change { session.dirty.insert(to) }
        }
        guard session.flush == nil else { return }
        // Coalesce bursts (a copy of thousands of files) into one round of work.
        session.flush = Task { [weak self, weak session] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let session else { return }
            session.flush = nil
            let paths = Array(session.dirty)
            let full = session.needsFullRescan
            session.dirty.removeAll()
            session.needsFullRescan = false
            await self.deliver(paths: paths, fullRescan: full, shareID: session.shareID, domain: domain)
        }
    }

    private func deliver(paths: [String], fullRescan: Bool, shareID: UUID, domain: NSFileProviderDomain) async {
        guard let proxy = await control(for: shareID) else { return }
        if fullRescan {
            await withCheckedContinuation { continuation in proxy.markDirty([""], recursive: true) { continuation.resume() } }
        }
        if !paths.isEmpty {
            await withCheckedContinuation { continuation in proxy.markDirty(paths, recursive: false) { continuation.resume() } }
        }
        if let manager = NSFileProviderManager(for: domain) {
            try? await Self.call { manager.signalEnumerator(for: .workingSet, completionHandler: $0) }
        }
    }

    // MARK: XPC

    private func push(_ configuration: CloudDomainConfiguration, password: String?, to shareID: UUID,
                      rootURL: URL) async throws {
        guard let proxy = await control(for: shareID, rootURL: rootURL) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "The Berth Cloud extension did not answer."])
        }
        let data = try JSONEncoder().encode(configuration)
        let message: String? = await withCheckedContinuation { continuation in
            proxy.configure(data, password: password) { continuation.resume(returning: $0) }
        }
        if let message {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func control(for shareID: UUID, rootURL: URL? = nil) async -> BerthCloudControl? {
        if let connection = controls[shareID],
           let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? BerthCloudControl {
            return proxy
        }
        var root = rootURL
        if root == nil, let path = await connectedPath(shareID) { root = URL(fileURLWithPath: path, isDirectory: true) }
        guard let root else { return nil }
        let serviceName = NSFileProviderServiceName(BerthCloud.controlServiceName)
        // ObjC objects cross the continuation boxed; they are only used on the main actor.
        let service = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedSendable<NSFileProviderService?>, Never>) in
            FileManager.default.getFileProviderServicesForItem(at: root) { services, _ in
                continuation.resume(returning: UncheckedSendable(services?[serviceName]))
            }
        }.value
        guard let service else { return nil }
        let connection = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedSendable<NSXPCConnection?>, Never>) in
            service.getFileProviderConnection { connection, _ in continuation.resume(returning: UncheckedSendable(connection)) }
        }.value
        guard let connection else { return nil }
        connection.remoteObjectInterface = NSXPCInterface(with: BerthCloudControl.self)
        connection.invalidationHandler = { [weak self] in
            // The Task must return Void: NSXPCConnection isn't Sendable.
            Task { @MainActor in _ = self?.controls.removeValue(forKey: shareID) }
        }
        connection.resume()
        controls[shareID] = connection
        return connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                let dead = self?.controls.removeValue(forKey: shareID)
                dead?.invalidate()
            }
        } as? BerthCloudControl
    }

    // MARK: Helpers

    static func configuration(for share: Share, address: ServerAddress, fallbacks: [ServerAddress]) -> CloudDomainConfiguration {
        let preferred = CloudDomainConfiguration.Endpoint(host: address.trimmedHost, port: address.effectivePort)
        let others = fallbacks
            .map { CloudDomainConfiguration.Endpoint(host: $0.trimmedHost, port: $0.effectivePort) }
            .filter { $0 != preferred && !$0.host.isEmpty }
        return CloudDomainConfiguration(
            shareID: share.id, displayName: share.name, endpoint: preferred, fallbacks: others,
            shareName: share.shareName, auth: share.auth, username: share.username, domain: share.domain,
            readOnly: share.options.readOnly, requireSigning: share.cloud.requireSigning,
            requireEncryption: share.cloud.requireEncryption,
            tuning: .recommended(preset: share.options.preset, link: address.resolvedKind))
    }

    static func domain(for share: Share) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: BerthCloud.domainIdentifier(for: share.id)),
                             displayName: share.name)
    }

    static func existingDomain(_ shareID: UUID) async -> NSFileProviderDomain? {
        let identifier = BerthCloud.domainIdentifier(for: shareID)
        let domains = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedSendable<[NSFileProviderDomain]>, Never>) in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                continuation.resume(returning: UncheckedSendable(domains))
            }
        }.value
        return domains.first { $0.identifier.rawValue == identifier }
    }

    /// Bridges a completion-handler API that reports only an optional error.
    static func call(_ body: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            body { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
