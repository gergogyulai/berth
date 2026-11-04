import Foundation

extension SpeedTest {
    /// The speed test for cloud shares, straight over BerthSMB. (Writing through the File
    /// Provider folder would only measure the local disk: uploads happen in the background.)
    public static func run(client: SMBClient, configuration: Configuration = .init(),
                           progress: @escaping @Sendable (Phase) -> Void) async throws -> Result {
        let dir = ".berth-speedtest-\(UUID().uuidString.prefix(8))"
        do {
            try await client.createDirectory(at: dir)
        } catch {
            throw TestError.io("Could not write to the share: \(error.localizedDescription)")
        }

        let local = FileManager.default.temporaryDirectory.appending(path: "berth-speedtest-\(UUID().uuidString)")
        let back = local.appendingPathExtension("read")
        let cleanup = {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: back)
        }
        defer { cleanup() }

        do {
            let chunks = max(1, configuration.fileSizeMB)
            var block = [UInt8](repeating: 0, count: 1 << 20)
            for i in stride(from: 0, to: block.count, by: 8) { block[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761) }
            FileManager.default.createFile(atPath: local.path, contents: nil)
            let handle = try FileHandle(forWritingTo: local)
            for _ in 0..<chunks { try handle.write(contentsOf: block) }
            try handle.close()

            let clock = ContinuousClock()
            var start = clock.now
            try await client.upload(local, to: "\(dir)/sequential.bin") { done, total in
                progress(.writing(total > 0 ? Double(done) / Double(total) : 1))
            }
            let writeSeconds = (clock.now - start).timeInterval

            start = clock.now
            try await client.download("\(dir)/sequential.bin", to: back) { done, total in
                progress(.reading(total > 0 ? Double(done) / Double(total) : 1))
            }
            let readSeconds = (clock.now - start).timeInterval

            let count = max(10, configuration.metadataFileCount)
            start = clock.now
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<count {
                    if i >= 16 { _ = try await group.next() }
                    group.addTask {
                        let name = "\(dir)/m\(i)"
                        try await client.write([], to: name)
                        _ = try await client.item(at: name)
                        try await client.removeItem(at: name)
                    }
                    if i % 10 == 0 { progress(.metadata(Double(i) / Double(count))) }
                }
                try await group.waitForAll()
            }
            let metaSeconds = (clock.now - start).timeInterval
            progress(.metadata(1))
            try? await client.removeItem(at: dir, recursive: true, ignoreMissing: true)

            let mb = Double(chunks)
            return Result(writeMBps: mb / max(writeSeconds, 0.001), readMBps: mb / max(readSeconds, 0.001),
                          metadataOpsPerSecond: Double(count * 3) / max(metaSeconds, 0.001),
                          fileSizeMB: chunks, date: Date())
        } catch {
            Task { try? await client.removeItem(at: dir, recursive: true, ignoreMissing: true) }
            if error is CancellationError || (error as? SMBError) == .cancelled { throw TestError.cancelled }
            if let error = error as? TestError { throw error }
            throw TestError.io(error.localizedDescription)
        }
    }
}
