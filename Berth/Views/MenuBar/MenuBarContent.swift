import SwiftUI
import BerthKit

/// The menu bar menu. A native menu (not a popover) so it behaves like every other status item:
/// keyboard navigation, type-select, ⌥-click alternates.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.config.shares.isEmpty {
            Button("New Share…") { model.showMainWindow(route: .newShare(prefill: nil)) }
            Button("Import from Finder…") { model.showMainWindow(route: .importShares) }
        } else if model.config.groups.isEmpty {
            ForEach(model.config.shares) { share in ShareMenu(share: share) }
        } else {
            let ungrouped = model.config.shares.filter { model.config.group(id: $0.groupID) == nil }
            ForEach(ungrouped) { share in ShareMenu(share: share) }
            ForEach(model.config.groups) { group in
                let members = model.config.shares(inGroup: group.id)
                if !members.isEmpty {
                    Section(group.name) {
                        ForEach(members) { share in ShareMenu(share: share) }
                    }
                }
            }
        }

        Divider()

        if !model.config.shares.isEmpty {
            Button("Mount All") { model.coordinator.mountAll() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Unmount All") { Task { await model.coordinator.unmountAll() } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.coordinator.mountedCount == 0)
            Divider()
        }

        Text(networkLine(model.network.snapshot))
        Divider()

        Button("Open Berth") { model.showMainWindow() }
            .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Berth") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func networkLine(_ s: NetworkSnapshot) -> String {
        guard s.isOnline else { return String(localized: "Offline") }
        var parts: [String] = []
        if let ssid = s.ssid { parts.append(ssid) } else if s.usesWired { parts.append(String(localized: "Ethernet")) }
        parts.append(s.tailscale.isUp ? String(localized: "Tailscale Connected") : String(localized: "Tailscale Off"))
        if s.isExpensive || s.isConstrained { parts.append(String(localized: "Metered")) }
        return parts.joined(separator: " · ")
    }
}

/// One share: click to mount or unmount; the submenu holds everything else.
private struct ShareMenu: View {
    @Environment(AppModel.self) private var model
    let share: Share

    var body: some View {
        let rt = model.runtime(share.id)
        Menu {
            if let path = rt.mountPoint, rt.state.isMounted {
                Button("Open in Finder") { FinderIntegration.open(path) }
                Button("Open in \(FinderIntegration.preferredTerminal.name)") { FinderIntegration.openInTerminal(path) }
                Button("Copy Path") { FinderIntegration.copyPath(path) }
                Divider()
                Button("Unmount") { Task { await model.coordinator.unmount(share.id) } }
                Button("Reconnect") { model.coordinator.reconnect(share.id) }
            } else if rt.isTrying {
                Button("Stop Trying") { Task { await model.coordinator.unmount(share.id) } }
            } else {
                Button("Mount") { model.coordinator.mount(share.id) }
            }
            if rt.state == .authFailed {
                Button("Update Password…") { model.showMainWindow(route: .changeCredentials(share.id)) }
            }
            Divider()
            Button("Show in Berth") { model.showMainWindow(route: .select(share.id)) }
        } label: {
            if let image = IconRenderer.menuImage(for: share.icon) {
                Image(nsImage: image)
            }
            Text(share.name)
            Text(subtitle(rt))
        } primaryAction: {
            model.coordinator.toggle(share.id)
        }
    }

    private func subtitle(_ rt: ShareRuntime) -> String {
        if rt.state.isProblem, let error = rt.lastError { return error }
        if rt.state == .disconnected { return String(localized: "Not Mounted") }
        return rt.state.title
    }
}
