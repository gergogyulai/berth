import Foundation

/// Metadata operations. Each one is a single compound round trip unless noted.
extension SMBClient {
    /// Attributes and file id of one item.
    public func item(at path: String) async throws -> SMBItem {
        try await perform(idempotent: true) { tree in try await Self.stat(tree, path) }
    }

    static func stat(_ tree: SMBTree, _ path: String) async throws -> SMBItem {
        let r = try await tree.compound([
            Requests.create(path: SMBPath.wire(path), access: [.readAttributes, .synchronize],
                            disposition: .open, options: []),
            Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
            Requests.close(.related),
        ])
        try r[0].check()
        let create = try CreateResponse(r[0])
        let fileID = r[1].status.isSuccess ? (try? r[1].outputBuffer().u64(0)) ?? 0 : 0
        return SMBItem(path: SMBPath.normalize(path), stat: create.stat, fileID: fileID)
    }

    /// Whether something exists at `path`.
    public func exists(_ path: String) async throws -> Bool {
        do {
            _ = try await item(at: path)
            return true
        } catch let error as SMBError where error.ntStatus?.isNotFound == true {
            return false
        }
    }

    /// The contents of a directory, without "." and "..".
    ///
    /// Directories that fit in two QUERY_DIRECTORY buffers (thousands of entries) are listed in
    /// one round trip: CREATE + QUERY_DIRECTORY + QUERY_DIRECTORY + CLOSE as a single compound.
    public func contentsOfDirectory(at path: String) async throws -> [SMBItem] {
        try await perform(idempotent: true) { tree in try await Self.list(tree, path) }
    }

    static func list(_ tree: SMBTree, _ path: String) async throws -> [SMBItem] {
        let wire = SMBPath.wire(path)
        let base = SMBPath.normalize(path)
        let bufferSize = min(tree.tuning.directoryBufferSize, tree.transactSize)
        let open = Requests.create(path: wire, access: [.readData, .readAttributes, .synchronize],
                                   disposition: .open, options: [.directoryFile])
        let first = Requests.queryDirectory(.related, infoClass: .idFullDirectory,
                                            flags: SMBQueryDirectoryFlag.restartScans, pattern: "*",
                                            outputLength: bufferSize)
        let second = Requests.queryDirectory(.related, infoClass: .idFullDirectory, flags: 0, pattern: "*",
                                             outputLength: bufferSize)
        let r = try await tree.compound([open, first, second, Requests.close(.related)])
        try r[0].check()

        var items: [SMBItem] = []
        func collect(_ message: SMBMessage) throws {
            for entry in try DirectoryParser.entries(message.outputBuffer()) where entry.name != "." && entry.name != ".." {
                items.append(SMBItem(path: SMBPath.join(base, entry.name), stat: entry.stat, fileID: entry.fileID))
            }
        }

        if r[1].status == .noMoreFiles { return items }
        try r[1].check()
        try collect(r[1])
        if r[2].status == .noMoreFiles { return items }
        try r[2].check()

        // Big directory: the compound closed the handle mid-listing. Do it the long way.
        items.removeAll(keepingCapacity: true)
        let handle = try CreateResponse(try await tree.send(open).checked()).fileID
        do {
            var flags = SMBQueryDirectoryFlag.restartScans
            while true {
                let message = try await tree.send(Requests.queryDirectory(
                    handle, infoClass: .idFullDirectory, flags: flags, pattern: "*", outputLength: bufferSize))
                flags = 0
                if message.status == .noMoreFiles { break }
                try message.check()
                try collect(message)
            }
        } catch {
            tree.closeDetached(handle)
            throw error
        }
        _ = try? await tree.send(Requests.close(handle))
        return items
    }

    /// Creates a directory and returns it.
    @discardableResult
    public func createDirectory(at path: String) async throws -> SMBItem {
        try await perform(idempotent: false) { tree in
            let r = try await tree.compound([
                Requests.create(path: SMBPath.wire(path), access: [.readAttributes, .synchronize],
                                disposition: .create, options: [.directoryFile]),
                Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
                Requests.close(.related, postQueryAttributes: true),
            ])
            try r[0].check()
            let create = try CreateResponse(r[0])
            let fileID = r[1].status.isSuccess ? (try? r[1].outputBuffer().u64(0)) ?? 0 : 0
            return SMBItem(path: SMBPath.normalize(path), stat: create.stat, fileID: fileID)
        }
    }

    /// Deletes a file or (empty, unless `recursive`) directory. Missing items are not an error
    /// when `ignoreMissing` is set.
    public func removeItem(at path: String, recursive: Bool = false, ignoreMissing: Bool = false) async throws {
        try await perform(idempotent: false) { tree in
            try await Self.remove(tree, path, recursive: recursive, ignoreMissing: ignoreMissing)
        }
    }

    static func remove(_ tree: SMBTree, _ path: String, recursive: Bool, ignoreMissing: Bool) async throws {
        let status = try await deleteOne(tree, path, clearReadOnly: false)
        switch status {
        case .success:
            return
        case .cannotDelete:
            try await deleteOne(tree, path, clearReadOnly: true).throwIfError()
        case .directoryNotEmpty where recursive:
            let children = try await list(tree, path)
            try await withThrowingTaskGroup(of: Void.self) { group in
                var running = 0
                for child in children {
                    if running >= tree.tuning.parallelFiles {
                        _ = try await group.next()
                        running -= 1
                    }
                    group.addTask {
                        try await SMBClient.remove(tree, child.path, recursive: true, ignoreMissing: true)
                    }
                    running += 1
                }
                try await group.waitForAll()
            }
            try await deleteOne(tree, path, clearReadOnly: false).throwIfError()
        default:
            if ignoreMissing && status.isNotFound { return }
            try status.throwIfError()
        }
    }

    /// Marks `path` delete-on-close (works for files and directories; a non-empty directory
    /// reports STATUS_DIRECTORY_NOT_EMPTY right away).
    private static func deleteOne(_ tree: SMBTree, _ path: String, clearReadOnly: Bool) async throws -> NTStatus {
        var requests = [Requests.create(path: SMBPath.wire(path),
                                        access: clearReadOnly ? [.delete, .readAttributes, .writeAttributes] : [.delete, .readAttributes],
                                        disposition: .open, options: [])]
        if clearReadOnly {
            requests.append(Requests.setInfo(.related, infoClass: .basic, buffer: Requests.basicInfo(attributes: .normal)))
        }
        requests.append(Requests.setInfo(.related, infoClass: .disposition, buffer: Requests.dispositionInfo(deletePending: true)))
        requests.append(Requests.close(.related))
        let r = try await tree.compound(requests)
        if r[0].status.isError { return r[0].status }
        for message in r.dropFirst().dropLast() where message.status.isError { return message.status }
        return .success
    }

    /// Renames and/or moves an item within the share.
    @discardableResult
    public func moveItem(at source: String, to destination: String, replaceExisting: Bool = false) async throws -> SMBItem {
        try await perform(idempotent: false) { tree in
            let r = try await tree.compound([
                Requests.create(path: SMBPath.wire(source), access: [.delete, .readAttributes, .synchronize],
                                disposition: .open, options: []),
                Requests.setInfo(.related, infoClass: .rename,
                                 buffer: Requests.renameInfo(target: SMBPath.wire(destination), replaceIfExists: replaceExisting)),
                Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
                Requests.close(.related, postQueryAttributes: true),
            ])
            try r[0].check()
            try r[1].check()
            let create = try CreateResponse(r[0])
            let stat = (try? CloseResponse(r[3]).stat) ?? create.stat
            let fileID = r[2].status.isSuccess ? (try? r[2].outputBuffer().u64(0)) ?? 0 : 0
            return SMBItem(path: SMBPath.normalize(destination), stat: stat, fileID: fileID)
        }
    }

    /// Sets timestamps and/or attributes. nil leaves a value unchanged.
    @discardableResult
    public func setAttributes(at path: String, modificationDate: Date? = nil, creationDate: Date? = nil,
                              attributes: SMBFileAttributes? = nil) async throws -> SMBItem {
        try await perform(idempotent: true) { tree in
            let info = Requests.basicInfo(creation: creationDate.map(FileTime.value) ?? 0,
                                          lastWrite: modificationDate.map(FileTime.value) ?? 0,
                                          attributes: attributes ?? [])
            let r = try await tree.compound([
                Requests.create(path: SMBPath.wire(path), access: [.readAttributes, .writeAttributes, .synchronize],
                                disposition: .open, options: []),
                Requests.setInfo(.related, infoClass: .basic, buffer: info),
                Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
                Requests.close(.related, postQueryAttributes: true),
            ])
            try r[0].check()
            try r[1].check()
            let create = try CreateResponse(r[0])
            let stat = (try? CloseResponse(r[3]).stat) ?? create.stat
            let fileID = r[2].status.isSuccess ? (try? r[2].outputBuffer().u64(0)) ?? 0 : 0
            return SMBItem(path: SMBPath.normalize(path), stat: stat, fileID: fileID)
        }
    }

    /// Size and free space of the share's volume.
    public func spaceInfo() async throws -> SMBSpaceInfo {
        try await perform(idempotent: true) { tree in
            let r = try await tree.compound([
                Requests.create(path: "", access: [.readAttributes, .synchronize], disposition: .open, options: [.directoryFile]),
                Requests.queryInfo(.related, type: .fileSystem, infoClass: SMBFSInfoClass.fullSize.rawValue, outputLength: 32),
                Requests.close(.related),
            ])
            try r[0].check()
            try r[1].check()
            let b = try r[1].outputBuffer()
            let total = try b.u64(0)
            let available = try b.u64(8)
            let sectorsPerUnit = try b.u32(24)
            let bytesPerSector = try b.u32(28)
            let unit = Int64(sectorsPerUnit) * Int64(bytesPerSector)
            return SMBSpaceInfo(totalBytes: Int64(clamping: total) &* unit,
                                availableBytes: Int64(clamping: available) &* unit)
        }
    }

    /// One SMB2 ECHO round trip: a cheap liveness probe that also measures latency.
    public func echo() async throws -> Duration {
        try await perform(idempotent: true) { tree in
            let clock = ContinuousClock()
            let start = clock.now
            try await tree.send(Requests.echo()).check()
            return clock.now - start
        }
    }
}

extension SMBMessage {
    func checked() throws -> SMBMessage {
        try check()
        return self
    }
}

extension NTStatus {
    func throwIfError() throws {
        if isError { throw SMBError.status(self) }
    }
}
