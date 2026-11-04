import Foundation

/// What the share's file system supports (FileFsAttributeInformation).
public struct SMBVolumeInfo: Sendable, Hashable {
    public var attributes: SMBFileSystemAttributes
    public var maximumComponentLength: Int
    /// "NTFS", "ZFS", "btrfs"… (Samba reports NTFS whatever is underneath).
    public var fileSystemName: String

    public var supportsNamedStreams: Bool { attributes.contains(.namedStreams) }
    public var supportsReparsePoints: Bool { attributes.contains(.reparsePoints) }
}

/// How a symbolic link was (or should be) stored on the server.
public enum SMBSymbolicLinkStyle: Sendable, Hashable {
    /// A reparse point when the server can store one, otherwise an XSym file.
    case automatic
    /// An NTFS symbolic link reparse point (relative targets only).
    case reparsePoint
    /// A Minshall-French "XSym" file, as macOS smbfs and Linux cifs (`mfsymlinks`) write them.
    case xsym
}

extension SMBClient {
    // MARK: Volume

    /// The share's file system attributes. Cached per connection.
    public func volumeInfo() async throws -> SMBVolumeInfo {
        try await perform(idempotent: true) { tree in try await Self.volumeInfo(tree) }
    }

    static func volumeInfo(_ tree: SMBTree) async throws -> SMBVolumeInfo {
        if let cached = tree.features.withLock({ $0.volume }) { return cached }
        let r = try await tree.compound([
            Requests.create(path: "", access: [.readAttributes, .synchronize], disposition: .open, options: [.directoryFile]),
            Requests.queryInfo(.related, type: .fileSystem, infoClass: SMBFSInfoClass.attribute.rawValue, outputLength: 1024),
            Requests.close(.related),
        ])
        try r[0].check()
        tree.closeIfLeaked(r)
        try r[1].check()
        let b = try r[1].outputBuffer()
        let nameLength = Int(try b.u32(8))
        let info = SMBVolumeInfo(attributes: SMBFileSystemAttributes(rawValue: try b.u32(0)),
                                 maximumComponentLength: Int(try b.u32(4)),
                                 fileSystemName: (try? b.utf16(12, byteCount: min(nameLength, b.count - 12))) ?? "")
        tree.features.withLock { $0.volume = info }
        return info
    }

    // MARK: Symbolic links

    /// The target of the symbolic link at `path`, or nil when it isn't one.
    ///
    /// Understands NTFS and NFS symlink reparse points and XSym files. Costs one round trip
    /// (CREATE + FSCTL_GET_REPARSE_POINT + READ + CLOSE); call it for items whose
    /// `mightBeSymbolicLink` is true.
    public func symbolicLinkDestination(at path: String) async throws -> String? {
        try await perform(idempotent: true) { tree in try await Self.linkDestination(tree, path) }
    }

    static func linkDestination(_ tree: SMBTree, _ path: String) async throws -> String? {
        let size = SymlinkCodec.xsymFileSize
        let r = try await tree.compound([
            Requests.create(path: SMBPath.wire(path), access: [.readData, .readAttributes, .synchronize],
                            disposition: .open, options: [.openReparsePoint]),
            Requests.fsctl(.related, code: SMBFSControl.getReparsePoint, maxOutput: 16 * 1024),
            Requests.read(.related, offset: 0, length: size),
            Requests.close(.related),
        ])
        try r[0].check()
        tree.closeIfLeaked(r)
        let create = try CreateResponse(r[0])
        if create.stat.attributes.contains(.reparsePoint), r[1].status.isSuccess {
            return try SymlinkCodec.parseReparse(try IOCTLResponse(r[1]).output)
        }
        guard !create.stat.attributes.contains(.directory), create.stat.endOfFile == UInt64(size) else { return nil }
        if r[2].status.isSuccess {
            let read = try ReadResponse(r[2])
            return SymlinkCodec.parseXSym(read.buffer[read.data])
        }
        // Some servers fail the rest of a related compound after the failed FSCTL: read alone.
        return SymlinkCodec.parseXSym(try await contents(tree, path, limit: size))
    }

    /// Creates a symbolic link at `path` pointing to `destination` (a POSIX path, typically
    /// relative to the link's folder) and returns it.
    ///
    /// `.automatic` stores a real reparse point where the server supports them (Windows and
    /// NTFS-backed servers, with the right privilege) and falls back to an XSym file, which is
    /// what Macs using Finder's own SMB client write and read.
    @discardableResult
    public func createSymbolicLink(at path: String, destination: String, style: SMBSymbolicLinkStyle = .automatic,
                                   replaceExisting: Bool = false) async throws -> SMBItem {
        guard !destination.isEmpty, !destination.contains("\0") else {
            throw SMBError.invalidArgument("A symbolic link needs a target.")
        }
        var useReparse = style == .reparsePoint
        if style == .automatic, !destination.hasPrefix("/") {
            let info = try? await volumeInfo()
            let refused = try await tree().features.withLock { $0.reparseSymlinksUnsupported }
            useReparse = info?.supportsReparsePoints == true && !refused
        }
        if useReparse {
            do {
                return try await perform(idempotent: false) { tree in
                    try await Self.createReparseLink(tree, path, destination: destination, replaceExisting: replaceExisting)
                }
            } catch let error as SMBError where style == .automatic {
                guard let status = error.ntStatus, Self.isReparseRefusal(status) else { throw error }
                try await tree().features.withLock { $0.reparseSymlinksUnsupported = true }
            }
        }
        let data = try SymlinkCodec.xsym(target: destination)
        return try await write(data, to: path, replaceExisting: replaceExisting)
    }

    static func isReparseRefusal(_ status: NTStatus) -> Bool {
        status.isUnsupportedFeature || [.privilegeNotHeld, .accessDenied, .notAReparsePoint, .invalidParameter,
                                        .ioReparseTagInvalid, .ioReparseTagNotHandled, .ioReparseDataInvalid].contains(status)
    }

    private static func createReparseLink(_ tree: SMBTree, _ path: String, destination: String,
                                          replaceExisting: Bool) async throws -> SMBItem {
        if destination.hasPrefix("/") {
            throw SMBError.invalidArgument("Only relative symbolic links can be stored as reparse points.")
        }
        if replaceExisting {
            try await remove(tree, path, recursive: false, ignoreMissing: true)
        }
        let r = try await tree.compound([
            Requests.create(path: SMBPath.wire(path),
                            access: [.writeData, .writeAttributes, .readAttributes, .delete, .synchronize],
                            disposition: .create, options: [.openReparsePoint, .nonDirectoryFile]),
            Requests.fsctl(.related, code: SMBFSControl.setReparsePoint,
                           input: SymlinkCodec.reparseData(relativeTarget: destination), maxOutput: 0),
            Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
            Requests.close(.related, postQueryAttributes: true),
        ])
        try r[0].check()
        let handle = try CreateResponse(r[0]).fileID
        if r[1].status.isError {
            // Don't leave an empty file behind.
            if r[3].status.isError { tree.closeDetached(handle) }
            _ = try? await deleteOne(tree, wire: SMBPath.wire(path), clearReadOnly: false)
            throw SMBError.status(r[1].status)
        }
        tree.closeIfLeaked(r)
        return try await stat(tree, path)
    }

    /// Reads up to `limit` bytes from the start of a file in one round trip.
    static func contents(_ tree: SMBTree, _ path: String, limit: Int, wire: String? = nil) async throws -> [UInt8] {
        let r = try await tree.compound([
            Requests.create(path: wire ?? SMBPath.wire(path), access: [.readData, .readAttributes, .synchronize],
                            disposition: .open, options: [.nonDirectoryFile]),
            Requests.read(.related, offset: 0, length: max(1, limit)),
            Requests.close(.related),
        ])
        try r[0].check()
        tree.closeIfLeaked(r)
        if r[1].status == .endOfFile { return [] }
        try r[1].check()
        let read = try ReadResponse(r[1])
        return Array(read.buffer[read.data])
    }
}
