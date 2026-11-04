import BerthKit
import FileProvider
import UniformTypeIdentifiers
import os

/// Berth Cloud: a File Provider (replicated) extension that presents an SMB share as a cloud
/// location, like iCloud Drive, using Berth's own SMB client instead of smbfs.
///
/// The system keeps a local replica in ~/Library/CloudStorage and calls this extension to list
/// folders, download files on demand and push local edits. All server I/O goes through
/// `CloudSyncEngine` (BerthKit) and `SMBClient` (BerthSMB).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {
    let domain: NSFileProviderDomain
    let engine: CloudSyncEngine?
    private let setupError: Error?
    private let manager: NSFileProviderManager?
    private let logger = Logger(subsystem: "app.berth.cloud", category: "extension")
    private lazy var control = ControlService(host: self)

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.manager = NSFileProviderManager(for: domain)
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let storage = support.appending(path: "BerthCloud/\(domain.identifier.rawValue)", directoryHint: .isDirectory)
            engine = try CloudSyncEngine(domainID: domain.identifier.rawValue, storage: storage)
            setupError = nil
        } catch {
            engine = nil
            setupError = error
        }
        super.init()
        if let setupError {
            logger.error("Could not open the index: \(String(describing: setupError), privacy: .public)")
        }
    }

    func invalidate() {}

    // MARK: Helpers

    private func requireEngine() throws -> CloudSyncEngine {
        guard let engine else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "Berth Cloud could not open its database: \(setupError.map { "\($0)" } ?? "unknown error")",
            ])
        }
        return engine
    }

    private var isReadOnly: Bool { engine?.configuration?.readOnly ?? false }

    func item(for record: CloudIndex.Record) -> CloudItem {
        CloudItem(record, readOnly: isReadOnly, rootName: engine?.configuration?.displayName ?? domain.displayName)
    }

    /// Runs async work for a File Provider callback and ties it to the returned Progress.
    private func run(_ progress: Progress, _ work: @escaping () async -> Void) -> Progress {
        let task = Task { await work() }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    static func fileProviderError(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if (error as NSError).domain == NSFileProviderErrorDomain { return error }
        if case CloudIndex.IndexError.anchorExpired? = error as? CloudIndex.IndexError {
            return NSFileProviderError(.syncAnchorExpired)
        }
        switch CloudError.from(error) {
        case .notConfigured: return NSFileProviderError(.notAuthenticated)
        case .noSuchItem: return NSFileProviderError(.noSuchItem)
        case .collision: return NSFileProviderError(.filenameCollision)
        case .directoryNotEmpty: return NSFileProviderError(.directoryNotEmpty)
        case .readOnly, .accessDenied: return CocoaError(.fileWriteNoPermission)
        case .quotaExceeded: return NSFileProviderError(.insufficientQuota)
        case .notAuthenticated: return NSFileProviderError(.notAuthenticated)
        case .unreachable: return NSFileProviderError(.serverUnreachable)
        case .cancelled: return CocoaError(.userCancelled)
        case .other(let message):
            return NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                           userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// Tells the system to come back for changes (after the app pushed new settings).
    func signalChanges() {
        manager?.signalEnumerator(for: .workingSet) { _ in }
        manager?.signalEnumerator(for: .rootContainer) { _ in }
    }

    // MARK: NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run(Progress(totalUnitCount: 1)) { [self] in
            do {
                guard identifier != .trashContainer, identifier != .workingSet else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let engine = try requireEngine()
                let id = identifier == .rootContainer ? CloudIndex.rootID : identifier.rawValue
                let record = try await engine.item(id)
                completionHandler(item(for: record), nil)
            } catch {
                completionHandler(nil, Self.fileProviderError(error))
            }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        return run(progress) { [self] in
            do {
                let engine = try requireEngine()
                // Same volume as the replica, so the system can move the file into place.
                let directory = (try? manager?.temporaryDirectoryURL()) ?? engine.temporaryDirectory
                let (url, record) = try await engine.fetchContents(itemIdentifier.rawValue, into: directory) { done, total in
                    if total > 0 {
                        progress.totalUnitCount = total
                        progress.completedUnitCount = done
                    }
                }
                completionHandler(url, item(for: record), nil)
            } catch {
                completionHandler(nil, nil, Self.fileProviderError(error))
            }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        run(Progress(totalUnitCount: 100)) { [self] in
            do {
                let engine = try requireEngine()
                let type = itemTemplate.contentType ?? .data
                let kind: CloudSyncEngine.NewItemKind
                if type.conforms(to: .folder) {
                    kind = .directory
                } else if type.conforms(to: .symbolicLink) {
                    // Stored the way Finder's own SMB client does it (a reparse point where the
                    // server allows, an XSym file otherwise), so Macs and Linux see a link too.
                    guard let target = itemTemplate.symlinkTargetPath ?? nil, !target.isEmpty else {
                        throw CocoaError(.featureUnsupported)
                    }
                    kind = .symbolicLink(target: target)
                } else {
                    // Aliases are ordinary files (bookmark data plus Finder info).
                    kind = .file(contents: url)
                }
                let parent = itemTemplate.parentItemIdentifier == .rootContainer
                    ? CloudIndex.rootID : itemTemplate.parentItemIdentifier.rawValue
                let modified = fields.contains(.contentModificationDate) ? (itemTemplate.contentModificationDate ?? nil) : nil
                var metadata = CloudSyncEngine.Metadata()
                if fields.contains(.extendedAttributes) {
                    metadata.extendedAttributes = itemTemplate.extendedAttributes ?? [:]
                }
                if fields.contains(.tagData) { metadata.tagData = itemTemplate.tagData ?? nil }
                let record = try await engine.create(in: parent, name: itemTemplate.filename, kind: kind,
                                                     modificationDate: modified, metadata: metadata,
                                                     mayAlreadyExist: options.contains(.mayAlreadyExist))
                completionHandler(item(for: record), [], false, nil)
            } catch {
                completionHandler(nil, [], false, Self.fileProviderError(error))
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        run(Progress(totalUnitCount: 100)) { [self] in
            do {
                let engine = try requireEngine()
                let id = item.itemIdentifier == .rootContainer ? CloudIndex.rootID : item.itemIdentifier.rawValue
                var parent: String?
                if changedFields.contains(.parentItemIdentifier) {
                    parent = item.parentItemIdentifier == .rootContainer ? CloudIndex.rootID : item.parentItemIdentifier.rawValue
                }
                let name = changedFields.contains(.filename) ? item.filename : nil
                let contents = changedFields.contains(.contents) ? newContents : nil
                let target = changedFields.contains(.contents) ? (item.symlinkTargetPath ?? nil) : nil
                let modified = changedFields.contains(.contentModificationDate) ? (item.contentModificationDate ?? nil) : nil
                let created = changedFields.contains(.creationDate) ? (item.creationDate ?? nil) : nil
                let attributes = changedFields.contains(.extendedAttributes) ? (item.extendedAttributes ?? [:]) : nil
                let tags: Data?? = changedFields.contains(.tagData) ? .some(item.tagData ?? nil) : .none
                let record = try await engine.modify(id, parentID: parent, name: name, contents: contents,
                                                     symlinkTarget: target, modificationDate: modified,
                                                     creationDate: created, extendedAttributes: attributes, tagData: tags)
                // Extended attributes and tags go to the server (as named streams or EAs); favorite
                // rank and last-used date stay local.
                completionHandler(self.item(for: record), [], false, nil)
            } catch {
                completionHandler(nil, [], false, Self.fileProviderError(error))
            }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        run(Progress(totalUnitCount: 1)) { [self] in
            do {
                try await requireEngine().delete(identifier.rawValue, recursive: options.contains(.recursive))
                completionHandler(nil)
            } catch {
                completionHandler(Self.fileProviderError(error))
            }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let engine = try requireEngine()
        switch containerItemIdentifier {
        case .workingSet:
            return WorkingSetEnumerator(engine: engine, host: self)
        case .trashContainer:
            return EmptyEnumerator(index: engine.index)
        default:
            guard engine.isConfigured else { throw NSFileProviderError(.notAuthenticated) }
            return DirectoryEnumerator(engine: engine, container: containerItemIdentifier, host: self)
        }
    }

    // MARK: NSFileProviderServicing

    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        completionHandler([control], nil)
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
}
