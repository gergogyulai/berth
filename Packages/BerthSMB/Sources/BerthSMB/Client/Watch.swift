import Foundation

extension SMBClient {
    /// Streams server-side changes under `path` using CHANGE_NOTIFY.
    ///
    /// The stream ends with an error when the connection drops; start a new one after
    /// reconnecting (and rescan, since changes may have been missed in between). Cancelling the
    /// consuming task cancels the outstanding notify request on the server.
    public func changes(under path: String = "", recursive: Bool = true) -> AsyncThrowingStream<[SMBChange], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.watchLoop(path: path, recursive: recursive) { batch in
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func watchLoop(path: String, recursive: Bool, emit: @Sendable ([SMBChange]) -> Void) async throws {
        let tree = try await self.tree()
        let base = SMBPath.normalize(path)
        let opened = try await tree.send(Requests.create(
            path: SMBPath.wire(base), access: [.readData, .readAttributes, .synchronize],
            disposition: .open, options: [.directoryFile]))
        try opened.check()
        let handle = try CreateResponse(opened).fileID
        defer { tree.closeDetached(handle) }

        while !Task.isCancelled {
            let message = try await tree.send(Requests.changeNotify(
                handle, recursive: recursive, filter: SMBNotifyFilter.allChanges, outputLength: 64 * 1024))
            switch message.status {
            case .notifyEnumDir:
                emit([.overflow])
                continue
            case .notifyCleanup, .cancelled:
                return
            default:
                try message.check()
            }
            var batch: [SMBChange] = []
            var pendingOldName: String?
            for (action, name) in try NotifyParser.entries(message.outputBuffer()) {
                let full = SMBPath.join(base, SMBPath.fromWire(name))
                switch action {
                case .added?: batch.append(.added(full))
                case .removed?: batch.append(.removed(full))
                case .modified?, .addedStream?, .removedStream?, .modifiedStream?: batch.append(.modified(full))
                case .renamedOldName?: pendingOldName = full
                case .renamedNewName?:
                    if let old = pendingOldName {
                        batch.append(.renamed(from: old, to: full))
                        pendingOldName = nil
                    } else {
                        batch.append(.added(full))
                    }
                case nil: batch.append(.modified(full))
                }
            }
            if let old = pendingOldName { batch.append(.removed(old)) }
            // An empty successful completion means the buffer overflowed on some servers.
            emit(batch.isEmpty ? [.overflow] : batch)
        }
    }
}
