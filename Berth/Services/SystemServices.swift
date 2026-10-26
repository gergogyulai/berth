import AppKit
import ServiceManagement
import BerthKit

/// Launch at login via SMAppService.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Installs the bundled `berth` tool on the user's PATH.
@MainActor
@Observable
final class CLIInstaller {
    static let shared = CLIInstaller()

    static let linkPath = "/usr/local/bin/berth"

    var bundledToolPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/berth").path
    }

    private(set) var lastError: String?

    var isInstalled: Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.linkPath) else { return false }
        return dest == bundledToolPath
    }

    var isOtherInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.linkPath) && !isInstalled
    }

    var installCommand: String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(bundledToolPath)' \(Self.linkPath)"
    }

    /// Creates the symlink, asking for an administrator password if /usr/local/bin isn't writable.
    func install() {
        lastError = nil
        let fm = FileManager.default
        if fm.isWritableFile(atPath: "/usr/local/bin") {
            try? fm.removeItem(atPath: Self.linkPath)
            do {
                try fm.createSymbolicLink(atPath: Self.linkPath, withDestinationPath: bundledToolPath)
                return
            } catch {
                // Fall through to the privileged path.
            }
        }
        let shell = "mkdir -p /usr/local/bin && ln -sf \(quoted(bundledToolPath)) \(Self.linkPath)"
        runPrivileged(shell)
    }

    func uninstall() {
        lastError = nil
        if (try? FileManager.default.removeItem(atPath: Self.linkPath)) != nil { return }
        runPrivileged("rm -f \(Self.linkPath)")
    }

    private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func runPrivileged(_ shell: String) {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Berth wants to install its command-line tool.\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "Installation failed."
        }
    }
}

/// Reads and writes ~/Library/Preferences/nsmb.conf.
enum NSMBConfEditor {
    static func load() -> NSMBConf { (try? NSMBConf.load()) ?? NSMBConf() }

    static func apply(_ preset: PerformancePreset, toHost host: String) throws {
        guard !host.isEmpty else { return }
        var conf = load()
        conf.withSection(named: NSMBConf.sectionName(forHost: host)) { preset.apply(to: &$0) }
        try conf.write()
    }
}
