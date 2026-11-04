import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Bulk data transfer.
///
/// Files move in `readSize`/`writeSize` chunks (1 MiB by default, up to the server's 8 MiB
/// maximum) with `ioDepth` requests in flight, so a single transfer keeps the link full even
/// over high-latency paths. Data goes straight from the received frame to the local file with
/// `pwrite` (and from the file into the outgoing frame with `pread`): one copy each way.
extension SMBClient {
    public typealias Progress = @Sendable (_ completed: Int64, _ total: Int64) -> Void

    /// Downloads `path` to `destination` (created or truncated).
    @discardableResult
    public func download(_ path: String, to destination: URL, progress: Progress? = nil) async throws -> SMBItem {
        try await perform(idempotent: true) { tree in
            try await Self.download(tree, path, to: destination, progress: progress)
        }
    }

    /// Reads a whole (small) file into memory.
    public func contents(of path: String) async throws -> [UInt8] {
        try await perform(idempotent: true) { tree in
            let (handle, item) = try await Self.openForReading(tree, path)
            do {
                var data = [UInt8](repeating: 0, count: Int(item.size))
                var offset = 0
                while offset < data.count {
                    let length = min(tree.readSize, data.count - offset)
                    let message = try await tree.send(Requests.read(handle, offset: UInt64(offset), length: length))
                    if message.status == .endOfFile { break }
                    try message.check()
                    let response = try ReadResponse(message)
                    if response.data.isEmpty { break }
                    data.replaceSubrange(offset..<(offset + response.data.count), with: response.buffer[response.data])
                    offset += response.data.count
                }
                tree.closeDetached(handle)
                if offset < data.count { data.removeSubrange(offset...) }
                return data
            } catch {
                tree.closeDetached(handle)
                throw error
            }
        }
    }

    /// Uploads `source` to `path`.
    ///
    /// The data goes to a hidden temporary file next to the destination, which is then renamed
    /// over it in the same round trip that sets its timestamps and closes it. Readers never see a
    /// half-written file, and a failed upload never clobbers the original.
    @discardableResult
    public func upload(_ source: URL, to path: String, replaceExisting: Bool = true,
                       modificationDate: Date? = nil, progress: Progress? = nil) async throws -> SMBItem {
        try await perform(idempotent: true) { tree in
            try await Self.upload(tree, source, to: path, replaceExisting: replaceExisting,
                                  modificationDate: modificationDate, progress: progress)
        }
    }

    /// Writes `data` to `path` (convenience for small files).
    @discardableResult
    public func write(_ data: [UInt8], to path: String, replaceExisting: Bool = true) async throws -> SMBItem {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("berth-smb-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(data)) else {
            throw SMBError.localIO(code: EIO, path: url.path)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return try await upload(url, to: path, replaceExisting: replaceExisting)
    }

    // MARK: Download

    static func openForReading(_ tree: SMBTree, _ path: String) async throws -> (SMBFileID, SMBItem) {
        let r = try await tree.compound([
            Requests.create(path: SMBPath.wire(path), access: [.readData, .readAttributes, .synchronize],
                            disposition: .open, options: [.nonDirectoryFile, .sequentialOnly]),
            Requests.queryInfo(.related, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
        ])
        try r[0].check()
        let create = try CreateResponse(r[0])
        let fileID = r[1].status.isSuccess ? (try? r[1].outputBuffer().u64(0)) ?? 0 : 0
        return (create.fileID, SMBItem(path: SMBPath.normalize(path), stat: create.stat, fileID: fileID))
    }

    static func download(_ tree: SMBTree, _ path: String, to destination: URL, progress: Progress?) async throws -> SMBItem {
        let (handle, item) = try await openForReading(tree, path)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            tree.closeDetached(handle)
            throw SMBError.posix(destination.path)
        }
        defer { _ = posixClose(fd) }
        do {
            if item.size > 0 { _ = ftruncate(fd, off_t(item.size)) }
            let received = try await pipelinedRead(tree, handle, fd: fd, size: item.size, progress: progress)
            if received < item.size { _ = ftruncate(fd, off_t(received)) } // the file shrank meanwhile
        } catch {
            tree.closeDetached(handle)
            throw error
        }
        _ = try? await tree.send(Requests.close(handle))
        return item
    }

    static func pipelinedRead(_ tree: SMBTree, _ handle: SMBFileID, fd: Int32, size: Int64,
                              progress: Progress?) async throws -> Int64 {
        guard size > 0 else {
            progress?(0, 0)
            return 0
        }
        let chunk = Int64(tree.readSize)
        let depth = max(1, tree.tuning.ioDepth)
        return try await withThrowingTaskGroup(of: Int64.self) { group in
            var next: Int64 = 0
            var running = 0
            var completed: Int64 = 0
            while next < size || running > 0 {
                while running < depth && next < size {
                    let offset = next
                    let length = Int(min(chunk, size - offset))
                    next += Int64(length)
                    running += 1
                    group.addTask {
                        try await SMBClient.readRange(tree, handle, fd: fd, offset: offset, length: length)
                    }
                }
                guard let done = try await group.next() else { break }
                running -= 1
                completed += done
                progress?(completed, size)
            }
            return completed
        }
    }

    private static func readRange(_ tree: SMBTree, _ handle: SMBFileID, fd: Int32, offset: Int64,
                                  length: Int) async throws -> Int64 {
        var position = offset
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let message = try await tree.send(Requests.read(handle, offset: UInt64(position), length: remaining))
            if message.status == .endOfFile { break }
            try message.check()
            let response = try ReadResponse(message)
            let count = response.data.count
            if count == 0 { break }
            let start = response.data.lowerBound
            let at = position
            try response.buffer.withUnsafeBytes { raw in
                var written = 0
                while written < count {
                    let n = pwrite(fd, raw.baseAddress! + start + written, count - written, off_t(at) + off_t(written))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw SMBError.posix("pwrite")
                    }
                    written += n
                }
            }
            position += Int64(count)
            remaining -= count
        }
        return Int64(length - remaining)
    }

    // MARK: Upload

    static func upload(_ tree: SMBTree, _ source: URL, to path: String, replaceExisting: Bool,
                       modificationDate: Date?, progress: Progress?) async throws -> SMBItem {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = modificationDate ?? (attributes?[.modificationDate] as? Date) ?? Date()
        let fd = open(source.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SMBError.posix(source.path) }
        defer { _ = posixClose(fd) }

        let target = SMBPath.normalize(path)
        let temp = SMBPath.join(SMBPath.parent(target), SMBClient.temporaryPrefix + randomHex(8))
        let created = try await tree.send(Requests.create(
            path: SMBPath.wire(temp),
            access: [.writeData, .readAttributes, .writeAttributes, .delete, .synchronize],
            disposition: .create, options: [.nonDirectoryFile, .sequentialOnly]))
        if created.status == .accessDenied {
            // No DELETE right (needed to rename): write in place instead.
            return try await uploadInPlace(tree, fd: fd, size: size, target: target, replaceExisting: replaceExisting,
                                           mtime: mtime, progress: progress)
        }
        try created.check()
        let handle = try CreateResponse(created).fileID

        do {
            try await pipelinedWrite(tree, handle, fd: fd, size: size, progress: progress)
            let r = try await tree.compound([
                Requests.setInfo(handle, infoClass: .basic, buffer: Requests.basicInfo(lastWrite: FileTime.value(mtime))),
                Requests.setInfo(handle, infoClass: .rename,
                                 buffer: Requests.renameInfo(target: SMBPath.wire(target), replaceIfExists: replaceExisting)),
                Requests.queryInfo(handle, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
                Requests.close(handle, postQueryAttributes: true),
            ])
            if r[1].status.isError {
                discard(tree, handle, path: temp)
                throw SMBError.status(r[1].status)
            }
            if r[3].status.isError { tree.closeDetached(handle) }
            let fileID = r[2].status.isSuccess ? (try? r[2].outputBuffer().u64(0)) ?? 0 : 0
            if let stat = try? CloseResponse(r[3]).stat {
                return SMBItem(path: target, stat: stat, fileID: fileID)
            }
            var item = try await SMBClient.stat(tree, target)
            if item.fileID == 0 { item.fileID = fileID }
            return item
        } catch {
            discard(tree, handle, path: temp)
            throw error
        }
    }

    /// Best-effort cleanup of an abandoned temporary upload (from a fresh task, so it runs even
    /// when the upload was cancelled).
    private static func discard(_ tree: SMBTree, _ handle: SMBFileID, path: String) {
        Task {
            let r = try? await tree.compound([
                Requests.setInfo(handle, infoClass: .disposition, buffer: Requests.dispositionInfo(deletePending: true)),
                Requests.close(handle),
            ])
            if r == nil || r?[0].status.isError == true {
                try? await SMBClient.remove(tree, path, recursive: false, ignoreMissing: true)
            }
        }
    }

    private static func uploadInPlace(_ tree: SMBTree, fd: Int32, size: Int64, target: String, replaceExisting: Bool,
                                      mtime: Date, progress: Progress?) async throws -> SMBItem {
        let created = try await tree.send(Requests.create(
            path: SMBPath.wire(target), access: [.writeData, .readAttributes, .writeAttributes, .synchronize],
            disposition: replaceExisting ? .overwriteIf : .create, options: [.nonDirectoryFile, .sequentialOnly]))
        try created.check()
        let handle = try CreateResponse(created).fileID
        do {
            try await pipelinedWrite(tree, handle, fd: fd, size: size, progress: progress)
        } catch {
            tree.closeDetached(handle)
            throw error
        }
        let r = try await tree.compound([
            Requests.setInfo(handle, infoClass: .basic, buffer: Requests.basicInfo(lastWrite: FileTime.value(mtime))),
            Requests.queryInfo(handle, type: .file, infoClass: SMBFileInfoClass.fileID.rawValue, outputLength: 8),
            Requests.close(handle, postQueryAttributes: true),
        ])
        let fileID = r[1].status.isSuccess ? (try? r[1].outputBuffer().u64(0)) ?? 0 : 0
        if let stat = try? CloseResponse(r[2]).stat { return SMBItem(path: target, stat: stat, fileID: fileID) }
        return try await SMBClient.stat(tree, target)
    }

    static func pipelinedWrite(_ tree: SMBTree, _ handle: SMBFileID, fd: Int32, size: Int64,
                               progress: Progress?) async throws {
        guard size > 0 else {
            progress?(0, 0)
            return
        }
        let chunk = Int64(tree.writeSize)
        let depth = max(1, tree.tuning.ioDepth)
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var next: Int64 = 0
            var running = 0
            var completed: Int64 = 0
            while next < size || running > 0 {
                while running < depth && next < size {
                    let offset = next
                    let length = Int(min(chunk, size - offset))
                    next += Int64(length)
                    running += 1
                    group.addTask {
                        try await SMBClient.writeRange(tree, handle, fd: fd, offset: offset, length: length)
                    }
                }
                guard let done = try await group.next() else { break }
                running -= 1
                completed += done
                progress?(completed, size)
            }
        }
    }

    private static func writeRange(_ tree: SMBTree, _ handle: SMBFileID, fd: Int32, offset: Int64,
                                   length: Int) async throws -> Int64 {
        var position = offset
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let at = position
            let count = remaining
            let request = try Requests.write(handle, offset: UInt64(at), length: count) { buffer in
                var filled = 0
                while filled < count {
                    let n = pread(fd, buffer.baseAddress! + filled, count - filled, off_t(at) + off_t(filled))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw SMBError.posix("pread")
                    }
                    if n == 0 { throw SMBError.localIO(code: EIO, path: "the file got shorter while uploading") }
                    filled += n
                }
            }
            let message = try await tree.send(request)
            try message.check()
            let written = try WriteResponse(message).count
            guard written > 0 else { throw SMBError.malformed("the server wrote 0 bytes") }
            position += Int64(written)
            remaining -= written
        }
        return Int64(length)
    }

    /// Name prefix of in-progress uploads. Listings in Berth hide these.
    public static let temporaryPrefix = ".berth-upload-"

    static func randomHex(_ bytes: Int) -> String {
        SMBCrypto.randomBytes(bytes).map { String(format: "%02x", $0) }.joined()
    }
}

@inline(__always)
func posixClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
