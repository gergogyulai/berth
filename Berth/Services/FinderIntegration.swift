import AppKit
import SwiftUI
import BerthKit

/// Finder-facing helpers: reveal, Terminal, sidebar pinning, custom volume icons.
@MainActor
enum FinderIntegration {
    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func copyURL(_ share: Share) {
        let url = SMBURL.make(address: share.addresses.first ?? ServerAddress(), share: share.shareName, auth: share.auth,
                              username: share.username, domain: share.domain)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url?.absoluteString ?? share.locationSummary, forType: .string)
    }

    // MARK: Terminal

    static let terminalDefaultsKey = "TerminalApplicationBundleID"

    struct TerminalApp: Identifiable, Hashable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    static let knownTerminals: [TerminalApp] = [
        TerminalApp(bundleID: "com.apple.Terminal", name: "Terminal"),
        TerminalApp(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        TerminalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        TerminalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        TerminalApp(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        TerminalApp(bundleID: "org.alacritty", name: "Alacritty"),
        TerminalApp(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
    ]

    static var installedTerminals: [TerminalApp] {
        knownTerminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static var preferredTerminal: TerminalApp {
        let id = UserDefaults.standard.string(forKey: terminalDefaultsKey) ?? "com.apple.Terminal"
        return installedTerminals.first { $0.bundleID == id } ?? knownTerminals[0]
    }

    static func openInTerminal(_ path: String) {
        let terminal = preferredTerminal
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: appURL, configuration: config)
    }

    // MARK: Post-mount / pre-unmount

    static func didMount(_ share: Share, at path: String) async {
        if share.pinToSidebar {
            let ok = await Task.detached { SharedFileList.pinToSidebar(path: path, name: share.name) }.value
            if !ok { AppModel.shared.log.add(.warning, "Could not pin to the Finder sidebar", share: share) }
        }
        if share.applyVolumeIcon {
            await applyVolumeIcon(share, at: path)
        }
    }

    static func willUnmount(_ share: Share, at path: String) {
        // A sidebar item pointing at an unmounted volume turns into a dead entry; remove it and
        // add it back on the next mount.
        if share.pinToSidebar { SharedFileList.unpinFromSidebar(path: path) }
    }

    /// Writes .VolumeIcon.icns to the share root. Best-effort: needs write access, and some
    /// servers ignore the Finder info flag.
    static func applyVolumeIcon(_ share: Share, at path: String) async {
        guard let image = IconRenderer.volumeImage(for: share.icon) else { return }
        let payload = UncheckedImage(image: image)
        let ok = await Blocking.run(timeout: .seconds(10)) {
            NSWorkspace.shared.setIcon(payload.image, forFile: path, options: [])
        } ?? false
        AppModel.shared.log.add(ok ? .debug : .warning, ok ? "Applied volume icon" : "Could not set the volume icon (read-only share?)", share: share)
    }

    struct UncheckedImage: @unchecked Sendable { let image: NSImage }
}

/// Renders a `ShareIcon` to an NSImage (menu bar, volume icon).
@MainActor
enum IconRenderer {
    static func volumeImage(for icon: ShareIcon) -> NSImage? {
        let renderer = ImageRenderer(content: ShareIconView(icon: icon, size: 512, style: .volume))
        renderer.scale = 2
        return renderer.nsImage
    }

    static func menuImage(for icon: ShareIcon, size: CGFloat = 16) -> NSImage? {
        let renderer = ImageRenderer(content: ShareIconView(icon: icon, size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }
}
