import Foundation
import AppKit
import BerthKit

// berth — command-line companion for Berth.app
//
// Talks to the running app over a per-user Unix socket, so mounting goes through the same engine
// (Keychain credentials, network rules, reconnect logic) as the UI.

let version = "1.0.0"

struct Options {
    var json = false
    var force = false
    var noWait = false
    var group: String?
    var positional: [String] = []
}

func usage() -> String {
    """
    berth \(version) — manage SMB shares with Berth

    USAGE
      berth <command> [options] [share]

    COMMANDS
      list                     List shares and their state (alias: ls)
      status [share]           Show detailed status
      mount <share>            Mount a share (by name, slug or id)
      mount --all              Mount every share  (or --group <name>)
      unmount <share>          Unmount a share (alias: umount, eject)
      unmount --all            Unmount every share  (or --group <name>)
      reconnect <share>        Force-unmount and mount again
      groups                   List share groups
      open <share>             Reveal the mounted share in Finder
      path <share>             Print the mount point (for scripting)

    OPTIONS
      -a, --all                Apply to all shares
      -g, --group <name>       Apply to a group
      -f, --force              Force unmount even if files are open
          --no-wait            Return immediately instead of waiting for the mount
          --json               Machine-readable output
      -h, --help               Show this help
      -v, --version            Show version

    EXAMPLES
      berth mount nas-media
      berth unmount --group Backups --force
      cd "$(berth path nas-media)"
    """
}

func parse(_ args: [String]) -> (String?, Options) {
    var options = Options()
    var command: String?
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--json": options.json = true
        case "-f", "--force": options.force = true
        case "--no-wait": options.noWait = true
        case "-a", "--all": options.group = "*"
        case "-g", "--group":
            i += 1
            if i < args.count { options.group = args[i] }
        case "-h", "--help": command = "help"
        case "-v", "--version": command = "version"
        default:
            if command == nil { command = arg } else { options.positional.append(arg) }
        }
        i += 1
    }
    return (command, options)
}

// MARK: Output

let isTTY = isatty(STDOUT_FILENO) != 0
func color(_ code: String, _ text: String) -> String { isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }

func stateColor(_ state: String) -> String {
    switch state {
    case "mounted": "32"
    case "connecting", "reconnecting", "waking", "unmounting": "36"
    case "stale", "host-unreachable", "tailscale-down": "33"
    case "auth-failed", "failed": "31"
    default: "2"
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("berth: \(message)\n".utf8))
    exit(code)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}

func printTable(_ shares: [IPC.ShareInfo]) {
    guard !shares.isEmpty else {
        print("No shares configured. Add one in Berth.")
        return
    }
    let nameWidth = max(4, shares.map(\.slug.count).max() ?? 4)
    let stateWidth = max(5, shares.map(\.stateTitle.count).max() ?? 5)
    print(color("1", "NAME".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  "
        + "STATE".padding(toLength: stateWidth, withPad: " ", startingAt: 0) + "  LOCATION"))
    for s in shares {
        let state = color(stateColor(s.state), s.stateTitle.padding(toLength: stateWidth, withPad: " ", startingAt: 0))
        let location = s.mountPoint ?? s.url
        print(s.slug.padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  " + state + "  " + location)
    }
}

func printDetail(_ s: IPC.ShareInfo) {
    func row(_ k: String, _ v: String?) { if let v, !v.isEmpty { print("  \(color("2", k.padding(toLength: 11, withPad: " ", startingAt: 0))) \(v)") } }
    print(color("1", s.name) + "  " + color(stateColor(s.state), s.stateTitle))
    row("Slug", s.slug)
    row("Group", s.group)
    row("Server", s.url)
    row("Address", s.address)
    row("Mounted at", s.mountPoint)
    row("Latency", s.latencyMs.map { String(format: "%.0f ms", $0) })
    row("Error", s.error)
}

// MARK: Transport

func send(_ request: IPC.Request, launchIfNeeded: Bool = true) -> IPC.Response {
    do {
        return try IPCClient.send(request)
    } catch IPCClient.ClientError.notRunning where launchIfNeeded {
        launchApp()
        for _ in 0..<50 {
            usleep(200_000)
            if let response = try? IPCClient.send(request) { return response }
        }
        fail("Berth did not start in time.")
    } catch {
        fail(error.localizedDescription)
    }
}

func launchApp() {
    if isTTY { FileHandle.standardError.write(Data("Starting Berth…\n".utf8)) }
    // Prefer the app this binary lives in (Berth.app/Contents/Helpers/berth).
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.addsToRecentItems = false
    let semaphore = DispatchSemaphore(value: 0)
    let appURL = bundle.pathExtension == "app" ? bundle : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.berth.Berth")
    guard let appURL else { fail("Could not find Berth.app.") }
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 10)
}

func shareTarget(_ options: Options, _ verb: String) -> String {
    guard let target = options.positional.first else { fail("\(verb): which share? Try `berth list`.", code: 64) }
    return target
}

// MARK: Main

let (command, options) = parse(Array(CommandLine.arguments.dropFirst()))

switch command {
case nil, "help":
    print(usage())

case "version":
    print("berth \(version)")

case "list", "ls":
    let response = send(IPC.Request(command: .list))
    guard response.ok else { fail(response.message ?? "Failed") }
    options.json ? printJSON(response.shares ?? []) : printTable(response.shares ?? [])

case "status":
    let response = send(IPC.Request(command: .status, target: options.positional.first))
    guard response.ok else { fail(response.message ?? "Failed") }
    if options.json {
        printJSON(response.shares ?? [])
    } else {
        for (i, share) in (response.shares ?? []).enumerated() {
            if i > 0 { print("") }
            printDetail(share)
        }
    }

case "mount":
    let request: IPC.Request
    if let group = options.group {
        request = IPC.Request(command: .mountAll, group: group == "*" ? nil : group, wait: !options.noWait)
    } else {
        request = IPC.Request(command: .mount, target: shareTarget(options, "mount"), wait: !options.noWait)
    }
    let response = send(request)
    if options.json { printJSON(response) } else if let message = response.message { print(message) }
    exit(response.ok ? 0 : 1)

case "unmount", "umount", "eject":
    let request: IPC.Request
    if let group = options.group {
        request = IPC.Request(command: .unmountAll, group: group == "*" ? nil : group, force: options.force)
    } else {
        request = IPC.Request(command: .unmount, target: shareTarget(options, "unmount"), force: options.force)
    }
    let response = send(request, launchIfNeeded: false)
    if options.json { printJSON(response) } else if let message = response.message { print(message) }
    exit(response.ok ? 0 : 1)

case "reconnect":
    let response = send(IPC.Request(command: .reconnect, target: shareTarget(options, "reconnect"), wait: !options.noWait))
    if let message = response.message { print(message) }
    exit(response.ok ? 0 : 1)

case "groups":
    let response = send(IPC.Request(command: .groups))
    guard response.ok else { fail(response.message ?? "Failed") }
    options.json ? printJSON(response.groups ?? []) : (response.groups ?? []).forEach { print($0) }

case "open", "path":
    let target = shareTarget(options, command!)
    let response = send(IPC.Request(command: .status, target: target))
    guard response.ok, let share = response.shares?.first else { fail(response.message ?? "No such share: \(target)") }
    guard let mountPoint = share.mountPoint else { fail("\(share.name) is not mounted.", code: 2) }
    if command == "path" {
        print(mountPoint)
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
    }

default:
    fail("unknown command “\(command!)”. See `berth --help`.", code: 64)
}
