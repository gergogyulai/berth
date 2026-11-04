import BerthSMB
import Foundation

// berth-smb: a small front end for BerthSMB, for trying the client against a server and for
// measuring it. Passwords can come from the URL or from $SMB_PASSWORD.

let usage = """
usage: berth-smb <command> smb://[DOMAIN;]user[:password]@host[:port]/share[/path] [options]

commands:
  info                       negotiate, sign in and print what was agreed
  ls                         list a directory
  stat                       show one item
  get <local-file>           download a file
  put <local-file>           upload a file (to the URL's path)
  mkdir | rm [-r] | mv <new-path>
  watch                      print change notifications until interrupted
  bench [--size MB] [--files N] [--io KiB] [--depth N]
                             upload/download throughput and metadata operations per second

environment: SMB_PASSWORD (when the URL has no password)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail(usage) }
let command = arguments.removeFirst()
let urlString = arguments.removeFirst()
guard var configuration = SMBClient.Configuration(url: urlString,
                                                  password: ProcessInfo.processInfo.environment["SMB_PASSWORD"]) else {
    fail("Not an smb:// URL with a share: \(urlString)")
}
let path = SMBClient.Configuration.path(fromURL: urlString)

@MainActor
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if let io = option("--io").flatMap(Int.init) { configuration.tuning.ioSize = io * 1024 }
if let depth = option("--depth").flatMap(Int.init) { configuration.tuning.ioDepth = depth }

let client = SMBClient(configuration)

func describe(_ item: SMBItem) -> String {
    let kind = item.isDirectory ? "d" : "-"
    let size = item.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    let date = item.modificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
    return "\(kind) \(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(date)  \(item.name.isEmpty ? "/" : item.name)"
}

func rate(_ bytes: Int64, _ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.1f MB/s", Double(bytes) / max(seconds, 1e-9) / 1_000_000)
}

// Top-level variables in main.swift are main-actor isolated (Swift 6).
@MainActor
func run() async throws {
    switch command {
    case "info":
        let info = try await client.connect()
        print("Connected to \(info.remote): \(info.summary)")
        print("  dialect      \(info.dialect)")
        print("  signing      \(info.signing.map(\.description) ?? "off")")
        print("  encryption   \(info.encryption.map(\.description) ?? "off")")
        print("  max read     \(info.maxReadSize) bytes, max write \(info.maxWriteSize), transact \(info.maxTransactSize)")
        print("  I/O size     \(info.ioSize) bytes × \(configuration.tuning.ioDepth) in flight")
        print("  multi-credit \(info.supportsMultiCredit)")
        print("  session      \(info.isAnonymous ? "anonymous" : info.isGuest ? "guest" : "authenticated")\(info.isReadOnly ? ", read-only" : "")")
        let latency = try await client.echo()
        print("  echo         \(latency)")

    case "ls":
        for item in try await client.contentsOfDirectory(at: path).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            print(describe(item))
        }

    case "stat":
        let item = try await client.item(at: path)
        print(describe(item))
        print("  file id \(item.fileID), attributes 0x\(String(item.attributes.rawValue, radix: 16)), allocated \(item.allocationSize)")

    case "get":
        guard let local = arguments.first else { fail(usage) }
        let clock = ContinuousClock()
        let start = clock.now
        let item = try await client.download(path, to: URL(fileURLWithPath: local))
        print("\(item.size) bytes in \(clock.now - start) (\(rate(item.size, clock.now - start)))")

    case "put":
        guard let local = arguments.first else { fail(usage) }
        let clock = ContinuousClock()
        let start = clock.now
        let item = try await client.upload(URL(fileURLWithPath: local), to: path)
        print("\(item.size) bytes in \(clock.now - start) (\(rate(item.size, clock.now - start)))")

    case "mkdir":
        print(describe(try await client.createDirectory(at: path)))

    case "rm":
        try await client.removeItem(at: path, recursive: arguments.contains("-r"))

    case "mv":
        guard let target = arguments.first else { fail(usage) }
        print(describe(try await client.moveItem(at: path, to: target)))

    case "watch":
        for try await batch in client.changes(under: path) {
            for change in batch { print(change) }
        }

    case "bench":
        try await bench()

    default:
        fail(usage)
    }
}

@MainActor
func bench() async throws {
    let smb = client
    let sizeMB = option("--size").flatMap(Int.init) ?? 256
    let files = option("--files").flatMap(Int.init) ?? 200
    let info = try await smb.connect()
    print("Server \(info.remote): \(info.summary)")
    let dir = SMBPath.join(path, ".berth-bench-\(UUID().uuidString.prefix(8))")
    try await smb.createDirectory(at: dir)

    let local = FileManager.default.temporaryDirectory.appendingPathComponent("berth-bench-\(UUID().uuidString)")
    let back = local.appendingPathExtension("back")
    defer {
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.removeItem(at: back)
    }
    let block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
    guard FileManager.default.createFile(atPath: local.path, contents: nil) else { fail("Could not create \(local.path)") }
    let handle = try FileHandle(forWritingTo: local)
    for _ in 0..<sizeMB { try handle.write(contentsOf: block) }
    try handle.close()
    let bytes = Int64(sizeMB) << 20

    let clock = ContinuousClock()
    var start = clock.now
    try await smb.upload(local, to: "\(dir)/payload.bin")
    print("upload    \(rate(bytes, clock.now - start))")
    start = clock.now
    try await smb.download("\(dir)/payload.bin", to: back)
    print("download  \(rate(bytes, clock.now - start))")
    let same = FileManager.default.contentsEqual(atPath: local.path, andPath: back.path)
    print("verify    \(same ? "ok" : "MISMATCH")")

    // Metadata: create, stat and delete small files with 32 operations in flight.
    start = clock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<files {
            if i >= 32 { _ = try await group.next() }
            group.addTask {
                let name = "\(dir)/m\(i)"
                _ = try await smb.createDirectory(at: name)
                _ = try await smb.item(at: name)
                try await smb.removeItem(at: name)
            }
        }
        try await group.waitForAll()
    }
    let elapsed = clock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    print(String(format: "metadata  %.0f ops/s (%d × create+stat+delete)", Double(files * 3) / seconds, files))
    let latency = try await smb.echo()
    print("latency   \(latency)")
    try await smb.removeItem(at: dir, recursive: true)
    if !same { exit(2) }
}

do {
    try await run()
    await client.disconnect()
} catch {
    fail("berth-smb: \(error)")
}
