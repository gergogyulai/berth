import Foundation

/// Where a share keeps macOS-style extended attributes.
public enum SMBAttributeStorage: String, Sendable, Codable, Hashable {
    /// Named streams (`file:name`), the format macOS smbfs and Samba's vfs_fruit use. Chosen
    /// whenever the share supports streams, so Macs mounting it in Finder see the same xattrs
    /// and tags.
    case namedStreams
    /// SMB extended attributes (EAs), for servers without named streams (Samba without
    /// streams_xattr maps them onto `user.*` xattrs). Names are escaped to fit EA rules, and
    /// empty values can't be stored.
    case extendedAttributes
    /// Neither works on this share.
    case none
}

/// Extended attributes ("xattrs") of server items, keyed by their macOS names
/// (`com.apple.metadata:_kMDItemUserTags`, `com.apple.FinderInfo`…).
extension SMBClient {
    /// How this share stores extended attributes. Cached per connection.
    public func attributeStorage() async throws -> SMBAttributeStorage {
        try await perform(idempotent: true) { tree in try await Self.attributeStorage(tree) }
    }

    static func attributeStorage(_ tree: SMBTree) async throws -> SMBAttributeStorage {
        let volume = try await volumeInfo(tree)
        if volume.supportsNamedStreams { return .namedStreams }
        return tree.features.withLock { $0.extendedAttributesUnsupported } ? .none : .extendedAttributes
    }

    /// Every extended attribute of the item at `path`.
    public func extendedAttributes(at path: String) async throws -> [String: [UInt8]] {
        try await perform(idempotent: true) { tree in
            switch try await Self.attributeStorage(tree) {
            case .namedStreams: return try await Self.streamAttributes(tree, path)
            case .extendedAttributes: return try await Self.eaAttributes(tree, path)
            case .none: return [:]
            }
        }
    }

    /// Sets (non-nil values) and removes (nil values) extended attributes, leaving the others
    /// alone, and returns the item afterwards. The item's modification date is preserved.
    @discardableResult
    public func setExtendedAttributes(_ changes: [String: [UInt8]?], at path: String) async throws -> SMBItem {
        try await perform(idempotent: true) { tree in
            switch try await Self.attributeStorage(tree) {
            case .namedStreams: return try await Self.setStreamAttributes(tree, path, changes)
            case .extendedAttributes: return try await Self.setEAAttributes(tree, path, changes)
            case .none: throw SMBError.unsupported("The share does not support extended attributes.")
            }
        }
    }

    /// Convenience for one attribute.
    public func extendedAttribute(_ name: String, at path: String) async throws -> [UInt8]? {
        try await extendedAttributes(at: path)[name]
    }

    // MARK: Named streams

    static func streamWirePath(_ path: String, attribute name: String) -> String {
        SMBPath.wire(path) + ":" + StreamCodec.streamName(forAttribute: name)
    }

    static func streamAttributes(_ tree: SMBTree, _ path: String) async throws -> [String: [UInt8]] {
        let r = try await tree.compound([
            Requests.create(path: SMBPath.wire(path), access: [.readAttributes, .synchronize],
                            disposition: .open, options: [.openReparsePoint]),
            Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.stream.rawValue,
                               outputLength: min(64 * 1024, tree.transactSize)),
            Requests.close(.related),
        ])
        try r[0].check()
        tree.closeIfLeaked(r)
        if r[1].status.isUnsupportedFeature { return [:] }
        try r[1].check()
        let streams = try StreamCodec.parseStreams(try r[1].outputBuffer())
        guard !streams.isEmpty else { return [:] }

        return try await withThrowingTaskGroup(of: (String, [UInt8])?.self) { group in
            for stream in streams {
                group.addTask {
                    let wire = SMBPath.wire(path) + ":" + stream.name
                    let data: [UInt8]
                    do {
                        data = try await SMBClient.readWhole(tree, wire: wire, size: stream.size)
                    } catch let error as SMBError where error.ntStatus?.isNotFound == true {
                        return nil // removed meanwhile
                    }
                    let name = StreamCodec.attributeName(forStream: stream.name)
                    if name == StreamCodec.finderInfoName {
                        guard let info = StreamCodec.finderInfo(fromAfpInfo: data), info.contains(where: { $0 != 0 }) else {
                            return nil
                        }
                        return (name, info)
                    }
                    return (name, data)
                }
            }
            var out: [String: [UInt8]] = [:]
            for try await entry in group {
                if let entry { out[entry.0] = entry.1 }
            }
            return out
        }
    }

    /// Reads a (stream) file whose size is roughly known: one round trip when it fits in a
    /// single READ.
    private static func readWhole(_ tree: SMBTree, wire: String, size: Int64) async throws -> [UInt8] {
        if size < Int64(tree.readSize) {
            // Ask for a little more in case it grew.
            return try await contents(tree, "", limit: min(tree.readSize, Int(size) + 4096), wire: wire)
        }
        let opened = try await tree.send(Requests.create(path: wire, access: [.readData, .readAttributes, .synchronize],
                                                         disposition: .open, options: [.nonDirectoryFile]))
        try opened.check()
        let create = try CreateResponse(opened)
        var data: [UInt8] = []
        do {
            while true {
                let message = try await tree.send(Requests.read(create.fileID, offset: UInt64(data.count), length: tree.readSize))
                if message.status == .endOfFile { break }
                try message.check()
                let read = try ReadResponse(message)
                if read.data.isEmpty { break }
                data += read.buffer[read.data]
            }
        } catch {
            tree.closeDetached(create.fileID)
            throw error
        }
        tree.closeDetached(create.fileID)
        return data
    }

    static func setStreamAttributes(_ tree: SMBTree, _ path: String, _ changes: [String: [UInt8]?]) async throws -> SMBItem {
        let before = try await stat(tree, path)
        let wroteAny = try await withThrowingTaskGroup(of: Bool.self) { group in
            for (name, value) in changes where !name.isEmpty {
                var value = value
                if name == StreamCodec.finderInfoName, let info = value {
                    value = info.contains(where: { $0 != 0 }) ? StreamCodec.afpInfo(finderInfo: info) : nil
                }
                let wire = streamWirePath(path, attribute: name)
                let data = value
                group.addTask {
                    guard let data else {
                        let status = try await SMBClient.deleteOne(tree, wire: wire, clearReadOnly: false)
                        if status.isError && !status.isNotFound { throw SMBError.status(status) }
                        return false
                    }
                    try await SMBClient.writeWhole(tree, wire: wire, data: data)
                    return true
                }
            }
            var any = false
            for try await didWrite in group { any = any || didWrite }
            return any
        }
        guard wroteAny else { return try await stat(tree, path) }
        // Writing a stream bumps the file's modification date (NTFS and Samba alike), which would
        // read as new contents. Put it back.
        let r = try await tree.compound([
            Requests.create(path: SMBPath.wire(path), access: [.readAttributes, .writeAttributes, .synchronize],
                            disposition: .open, options: [.openReparsePoint]),
            Requests.setInfo(.related, infoClass: .basic, buffer: Requests.basicInfo(lastWrite: before.lastWriteTime)),
            Requests.close(.related),
        ])
        tree.closeIfLeaked(r)
        var after = try await stat(tree, path)
        if after.fileID == 0 { after.fileID = before.fileID }
        return after
    }

    private static func writeWhole(_ tree: SMBTree, wire: String, data: [UInt8]) async throws {
        let open = Requests.create(path: wire, access: [.writeData, .readAttributes, .synchronize],
                                   disposition: .overwriteIf, options: [.nonDirectoryFile])
        if data.count <= tree.writeSize {
            var requests = [open]
            if !data.isEmpty { requests.append(Requests.write(.related, offset: 0, data: data)) }
            requests.append(Requests.close(.related))
            let r = try await tree.compound(requests)
            try r[0].check()
            tree.closeIfLeaked(r)
            for message in r.dropFirst().dropLast() { try message.check() }
            return
        }
        let opened = try await tree.send(open)
        try opened.check()
        let handle = try CreateResponse(opened).fileID
        do {
            var offset = 0
            while offset < data.count {
                let chunk = Array(data[offset..<min(data.count, offset + tree.writeSize)])
                let message = try await tree.send(Requests.write(handle, offset: UInt64(offset), data: chunk))
                try message.check()
                let written = try WriteResponse(message).count
                guard written > 0 else { throw SMBError.malformed("the server wrote 0 bytes") }
                offset += written
            }
        } catch {
            tree.closeDetached(handle)
            throw error
        }
        _ = try? await tree.send(Requests.close(handle))
    }

    // MARK: SMB EAs

    static func eaAttributes(_ tree: SMBTree, _ path: String) async throws -> [String: [UInt8]] {
        var length = min(64 * 1024, tree.transactSize)
        while true {
            let r = try await tree.compound([
                Requests.create(path: SMBPath.wire(path), access: [.readEA, .readAttributes, .synchronize],
                                disposition: .open, options: [.openReparsePoint]),
                Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fullEA.rawValue,
                                   outputLength: length, flags: SMBQueryInfoFlag.restartScan),
                Requests.close(.related),
            ])
            try r[0].check()
            tree.closeIfLeaked(r)
            let status = r[1].status
            if status == .noEAsOnFile { return [:] }
            if status.isUnsupportedFeature {
                tree.features.withLock { $0.extendedAttributesUnsupported = true }
                throw SMBError.status(status)
            }
            if status == .bufferOverflow || status == .bufferTooSmall {
                guard length < tree.transactSize else { throw SMBError.status(status) }
                length = tree.transactSize
                continue
            }
            try r[1].check()
            var out: [String: [UInt8]] = [:]
            for entry in try EACodec.parse(try r[1].outputBuffer()) { out[entry.name] = entry.value }
            return out
        }
    }

    static func setEAAttributes(_ tree: SMBTree, _ path: String, _ changes: [String: [UInt8]?]) async throws -> SMBItem {
        // An empty value deletes an EA, so empty attributes can't be stored: they're dropped.
        let entries = changes.filter { !$0.key.isEmpty }.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value ?? []) }
        guard !entries.isEmpty else { return try await stat(tree, path) }
        let buffer = try EACodec.encode(entries)
        let r = try await tree.compound([
            Requests.create(path: SMBPath.wire(path), access: [.writeEA, .readAttributes, .synchronize],
                            disposition: .open, options: [.openReparsePoint]),
            Requests.setInfo(.related, infoClass: .fullEA, buffer: buffer),
            Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
            Requests.close(.related, postQueryAttributes: true),
        ])
        try r[0].check()
        tree.closeIfLeaked(r)
        let status = r[1].status
        if status.isUnsupportedFeature {
            tree.features.withLock { $0.extendedAttributesUnsupported = true }
        }
        // STATUS_INVALID_EA_NAME and STATUS_EA_LIST_INCONSISTENT are warnings, but nothing was set.
        if status.isError || status == .invalidEAName || status == .eaListInconsistent {
            throw SMBError.status(status)
        }
        // CLOSE's attributes don't carry the EA size; stat again for the full picture.
        var item = try await stat(tree, path)
        if item.fileID == 0, r[2].status.isSuccess { item.fileID = (try? r[2].outputBuffer().u64(0)) ?? 0 }
        return item
    }
}
