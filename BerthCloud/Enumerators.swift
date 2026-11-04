import BerthKit
import FileProvider

/// Sync anchors are "<index epoch>:<change sequence>", so anchors from a rebuilt index are
/// recognised as expired instead of silently skipping changes.
enum Anchor {
    static func make(_ index: CloudIndex, _ sequence: Int64? = nil) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(index.epoch):\(sequence ?? index.currentAnchor)".utf8))
    }

    static func parse(_ anchor: NSFileProviderSyncAnchor) -> (epoch: String, sequence: Int64)? {
        guard let text = String(data: anchor.rawValue, encoding: .utf8),
              let colon = text.lastIndex(of: ":"),
              let sequence = Int64(text[text.index(after: colon)...]) else { return nil }
        return (String(text[..<colon]), sequence)
    }
}

/// Lists one directory, always fresh from the server (and reconciled into the index).
final class DirectoryEnumerator: NSObject, NSFileProviderEnumerator {
    private let engine: CloudSyncEngine
    private let container: String
    private let host: FileProviderExtension
    private var task: Task<Void, Never>?

    init(engine: CloudSyncEngine, container: NSFileProviderItemIdentifier, host: FileProviderExtension) {
        self.engine = engine
        self.container = container == .rootContainer ? CloudIndex.rootID : container.rawValue
        self.host = host
    }

    func invalidate() {
        task?.cancel()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let engine = engine
        let container = container
        let host = host
        task = Task {
            do {
                let records = try await engine.list(container)
                let items = records.filter { !$0.isRoot }.map { host.item(for: $0) }
                let pageSize = max(50, observer.suggestedPageSize ?? 500)
                var start = 0
                while start < items.count {
                    let end = min(items.count, start + pageSize)
                    observer.didEnumerate(Array(items[start..<end]))
                    start = end
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        }
    }

    /// Remote changes are reported through the working set.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Anchor.make(engine.index))
    }
}

/// The working set: every item the index knows. Its change enumeration is where remote edits
/// (found by re-listing directories the app's CHANGE_NOTIFY watch flagged) reach the system.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let engine: CloudSyncEngine
    private let host: FileProviderExtension
    private var task: Task<Void, Never>?
    private static let pageSize = 1000

    init(engine: CloudSyncEngine, host: FileProviderExtension) {
        self.engine = engine
        self.host = host
    }

    func invalidate() {
        task?.cancel()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Pages we hand out are decimal offsets; the system's initial pages aren't.
        let offset = String(data: page.rawValue, encoding: .utf8).flatMap { Int($0) } ?? 0
        do {
            let records = try engine.index.allRecords(offset: offset, limit: Self.pageSize)
            observer.didEnumerate(records.map { host.item(for: $0) })
            if records.count == Self.pageSize {
                observer.finishEnumerating(upTo: NSFileProviderPage(Data(String(offset + Self.pageSize).utf8)))
            } else {
                observer.finishEnumerating(upTo: nil)
            }
        } catch {
            observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let engine = engine
        let host = host
        task = Task {
            guard let parsed = Anchor.parse(anchor), parsed.epoch == engine.index.epoch else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            if engine.isConfigured { await engine.refresh() }
            do {
                let changes = try engine.index.changes(since: parsed.sequence)
                if !changes.updated.isEmpty {
                    observer.didUpdate(changes.updated.map { host.item(for: $0) })
                }
                if !changes.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.deleted.map(CloudItem.identifier))
                }
                observer.finishEnumeratingChanges(upTo: Anchor.make(engine.index, changes.anchor),
                                                  moreComing: changes.moreComing)
            } catch CloudIndex.IndexError.anchorExpired {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Anchor.make(engine.index))
    }
}

/// For containers this provider doesn't have (the trash).
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private let index: CloudIndex

    init(index: CloudIndex) { self.index = index }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Anchor.make(index))
    }
}
