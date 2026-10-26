import Foundation
import os

/// In-memory connection log (shown in Diagnostics), mirrored to unified logging and a plain-text
/// file in ~/Library/Logs/Berth for bug reports.
@MainActor
@Observable
public final class EventLog {
    public struct Entry: Identifiable, Hashable, Sendable, Codable {
        public enum Level: String, Sendable, Codable, CaseIterable, Comparable {
            case debug, info, warning, error

            public static func < (a: Level, b: Level) -> Bool {
                allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
            }

            public var symbol: String {
                switch self {
                case .debug: "ant"
                case .info: "info.circle"
                case .warning: "exclamationmark.triangle"
                case .error: "xmark.octagon"
                }
            }
        }

        public var id: UUID = UUID()
        public var date: Date
        public var level: Level
        public var shareID: UUID?
        public var shareName: String?
        public var message: String
    }

    public private(set) var entries: [Entry] = []
    public let capacity: Int

    @ObservationIgnored private let logger = Logger(subsystem: "app.berth", category: "events")
    @ObservationIgnored private let writer = LogFileWriter()

    public init(capacity: Int = 2_000) {
        self.capacity = capacity
    }

    nonisolated public static var logFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Berth/Berth.log")
    }

    public func add(_ level: Entry.Level, _ message: String, share: Share? = nil) {
        let entry = Entry(date: Date(), level: level, shareID: share?.id, shareName: share?.name, message: message)
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }

        let prefix = share.map { "[\($0.name)] " } ?? ""
        switch level {
        case .debug: logger.debug("\(prefix, privacy: .public)\(message, privacy: .public)")
        case .info: logger.info("\(prefix, privacy: .public)\(message, privacy: .public)")
        case .warning: logger.warning("\(prefix, privacy: .public)\(message, privacy: .public)")
        case .error: logger.error("\(prefix, privacy: .public)\(message, privacy: .public)")
        }
        if level != .debug { writer.append(entry) }
    }

    public func entries(for shareID: UUID) -> [Entry] { entries.filter { $0.shareID == shareID } }

    public func clear() { entries.removeAll() }

    /// Plain-text rendering for "Copy Diagnostics" / export.
    public func text(for list: [Entry]? = nil) -> String {
        (list ?? entries).map(LogFileWriter.format).joined(separator: "\n")
    }
}

/// Appends to ~/Library/Logs/Berth/Berth.log off the main thread, rotating at 2 MB.
final class LogFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.berth.logfile", qos: .background)
    private var handle: FileHandle?


    static func format(_ e: EventLog.Entry) -> String {
        let share = e.shareName.map { " [\($0)]" } ?? ""
        return "\(e.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))) \(e.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0))\(share) \(e.message)"
    }

    func append(_ entry: EventLog.Entry) {
        let line = Self.format(entry) + "\n"
        queue.async { [self] in
            let url = EventLog.logFileURL
            if handle == nil {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            if let size = try? handle?.offset(), size > 2_000_000 {
                try? handle?.close()
                handle = nil
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try? FileHandle(forWritingTo: url)
            }
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }
}
