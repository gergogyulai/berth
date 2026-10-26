import Foundation

/// Sequential read/write and metadata benchmark against a mounted share.
///
/// Writes a temporary file with the page cache disabled (F_NOCACHE) so the numbers reflect the
/// network and the server, not RAM. Everything it creates is removed afterwards, even on cancel.
public enum SpeedTest {
    public struct Configuration: Sendable {
        public var fileSizeMB: Int
        public var metadataFileCount: Int
        public init(fileSizeMB: Int = 256, metadataFileCount: Int = 100) {
            self.fileSizeMB = fileSizeMB
            self.metadataFileCount = metadataFileCount
        }
    }

    public struct Result: Sendable, Equatable, Codable {
        public var writeMBps: Double
        public var readMBps: Double
        /// Create + stat + delete operations per second.
        public var metadataOpsPerSecond: Double
        public var fileSizeMB: Int
        public var date: Date
    }

    public enum Phase: Sendable, Equatable {
        case writing(Double), reading(Double), metadata(Double)

        public var title: String {
            switch self {
            case .writing: "Writing"
            case .reading: "Reading"
            case .metadata: "Metadata"
            }
        }

        public var fraction: Double {
            switch self {
            case .writing(let f): f / 3
            case .reading(let f): (1 + f) / 3
            case .metadata(let f): (2 + f) / 3
            }
        }
    }

    public enum TestError: LocalizedError {
        case io(String)
        case cancelled
        public var errorDescription: String? {
            switch self {
            case .io(let m): m
            case .cancelled: "The speed test was cancelled."
            }
        }
    }

    public static func run(mountPoint: String, configuration: Configuration = .init(),
                           progress: @escaping @Sendable (Phase) -> Void) async throws -> Result {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    do {
                        let result = try runBlocking(mountPoint: mountPoint, configuration: configuration, cancelled: cancelled, progress: progress)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private static func runBlocking(mountPoint: String, configuration: Configuration, cancelled: CancelFlag,
                                    progress: @Sendable (Phase) -> Void) throws -> Result {
        let dir = (mountPoint as NSString).appendingPathComponent(".berth-speedtest-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: false) } catch {
            throw TestError.io("Could not write to the share: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(atPath: dir) }

        let file = (dir as NSString).appendingPathComponent("sequential.bin")
        let chunk = 1 << 20
        let chunks = max(1, configuration.fileSizeMB)
        var buffer = [UInt8](repeating: 0, count: chunk)
        for i in stride(from: 0, to: chunk, by: 8) { buffer[i] = UInt8(truncatingIfNeeded: i &* 2654435761) } // defeat compression

        // Write
        let clock = ContinuousClock()
        var fd = open(file, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw TestError.io(String(cString: strerror(errno))) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var start = clock.now
        for i in 0..<chunks {
            if cancelled.isSet { close(fd); throw TestError.cancelled }
            let n = buffer.withUnsafeBytes { write(fd, $0.baseAddress, chunk) }
            guard n == chunk else { let e = errno; close(fd); throw TestError.io("Write failed: \(String(cString: strerror(e)))") }
            if i % 8 == 0 { progress(.writing(Double(i) / Double(chunks))) }
        }
        fsync(fd)
        close(fd)
        let writeSeconds = (clock.now - start).timeInterval

        // Read
        fd = open(file, O_RDONLY)
        guard fd >= 0 else { throw TestError.io(String(cString: strerror(errno))) }
        _ = fcntl(fd, F_NOCACHE, 1)
        start = clock.now
        for i in 0..<chunks {
            if cancelled.isSet { close(fd); throw TestError.cancelled }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            guard n > 0 else { break }
            if i % 8 == 0 { progress(.reading(Double(i) / Double(chunks))) }
        }
        close(fd)
        let readSeconds = (clock.now - start).timeInterval
        unlink(file)

        // Metadata: create, stat, delete N small files.
        let count = max(10, configuration.metadataFileCount)
        start = clock.now
        for i in 0..<count {
            if cancelled.isSet { throw TestError.cancelled }
            let path = (dir as NSString).appendingPathComponent("m\(i)")
            let f = open(path, O_CREAT | O_WRONLY, 0o644)
            if f >= 0 { close(f) }
            var st = stat()
            _ = stat(path, &st)
            unlink(path)
            if i % 10 == 0 { progress(.metadata(Double(i) / Double(count))) }
        }
        let metaSeconds = (clock.now - start).timeInterval
        progress(.metadata(1))

        let mb = Double(chunks)
        return Result(
            writeMBps: mb / max(writeSeconds, 0.001),
            readMBps: mb / max(readSeconds, 0.001),
            metadataOpsPerSecond: Double(count * 3) / max(metaSeconds, 0.001),
            fileSizeMB: chunks,
            date: Date()
        )
    }
}
