import BerthKit
import FileProvider
import UniformTypeIdentifiers

/// An index record as File Provider sees it.
final class CloudItem: NSObject, NSFileProviderItem {
    let record: CloudIndex.Record
    private let readOnly: Bool
    private let rootName: String

    init(_ record: CloudIndex.Record, readOnly: Bool, rootName: String = "") {
        self.record = record
        self.readOnly = readOnly
        self.rootName = rootName
    }

    static func identifier(_ id: String) -> NSFileProviderItemIdentifier {
        id == CloudIndex.rootID ? .rootContainer : NSFileProviderItemIdentifier(id)
    }

    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.id) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        record.isRoot ? .rootContainer : Self.identifier(record.parentID)
    }

    var filename: String { record.isRoot ? rootName : record.name }

    var contentType: UTType {
        if record.isDirectory || record.isRoot { return .folder }
        let ext = (record.name as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    var capabilities: NSFileProviderItemCapabilities {
        let writable = !readOnly && !record.isReadOnly
        if record.isDirectory || record.isRoot {
            var caps: NSFileProviderItemCapabilities = [.allowsReading, .allowsContentEnumerating]
            if !readOnly {
                caps.insert(.allowsAddingSubItems)
                if !record.isRoot { caps.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting]) }
            }
            return caps
        }
        // Eviction is up to the system's content policy (allowsEvicting is deprecated).
        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if writable { caps.formUnion([.allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]) }
        return caps
    }

    var documentSize: NSNumber? { record.isDirectory ? nil : NSNumber(value: record.size) }

    var creationDate: Date? { record.creationDate }

    var contentModificationDate: Date? { record.modificationDate }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: record.contentVersion, metadataVersion: record.metadataVersion)
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        var flags: NSFileProviderFileSystemFlags = [.userReadable]
        if !readOnly && !record.isReadOnly { flags.insert(.userWritable) }
        if record.isDirectory || record.isRoot { flags.insert(.userExecutable) }
        if record.isHidden { flags.insert(.hidden) }
        return flags
    }
}
