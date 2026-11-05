import SwiftUI
import BerthKit

struct BerthCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.selectedShareIDs) private var selectedShareIDs

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Berth") { AboutPanel.show() }
        }

        CommandGroup(replacing: .appTermination) {
            Button("Quit Berth") { AppDelegate.closeWindowsOrQuit() }
                .keyboardShortcut("q")
        }

        CommandGroup(after: .appInfo) {
            Button("Install Command Line Tool…") {
                model.showSettings(tab: .automation)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Share…") { model.showMainWindow(route: .newShare(prefill: nil)) }
                .keyboardShortcut("n")
            Button("New Group") { model.showMainWindow(route: .newGroup) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Import Shares…") { model.showMainWindow(route: .importShares) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Export Configuration…") { ConfigTransfer.export(model: model) }
            Button("Import Configuration…") { ConfigTransfer.importConfiguration(model: model) }
        }

        CommandMenu("Share") {
            let ids = selectedShareIDs ?? []
            // `share` is set only for a single selection; several go through `batch`.
            let share = ids.count == 1 ? ids.first.flatMap { model.config.share(id: $0) } : nil
            let rt = share.map { model.runtime($0.id) }
            let batch = ShareBatch(model: model, ids: ids)
            let isBulk = ids.count > 1
            let paths = isBulk ? batch.mountPoints : [rt?.mountPoint].compactMap(\.self)

            if isBulk {
                // A mixed selection mounts first; pressing the shortcut again then unmounts.
                if batch.mountable.isEmpty {
                    Button("Unmount \(ShareBatch.countTitle(batch.unmountable.count))") { batch.unmount() }
                        .keyboardShortcut("m")
                        .disabled(batch.unmountable.isEmpty)
                } else {
                    Button("Mount \(ShareBatch.countTitle(batch.mountable.count))") { batch.mount() }
                        .keyboardShortcut("m")
                }
            } else {
                Button(rt?.state.isMounted == true ? "Unmount" : "Mount") {
                    if let share { model.coordinator.toggle(share.id) }
                }
                .keyboardShortcut("m")
                .disabled(share == nil)
            }

            Button("Reconnect") {
                if let share { model.coordinator.reconnect(share.id) } else { batch.reconnect() }
            }
            .keyboardShortcut("r")
            .disabled(isBulk ? batch.mounted.isEmpty : share == nil)

            Button("Force Unmount") {
                if let share { Task { await model.coordinator.unmount(share.id, force: true) } } else { batch.forceUnmount() }
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(isBulk ? batch.stale.isEmpty : rt?.state.isMounted != true)

            Divider()

            Button("Open in Finder") { paths.forEach(FinderIntegration.open) }
                .keyboardShortcut("o")
                .disabled(paths.isEmpty)
            Button("Open in \(FinderIntegration.preferredTerminal.name)") { if let path = rt?.mountPoint { FinderIntegration.openInTerminal(path) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(rt?.mountPoint == nil)
            Button(isBulk ? "Copy Paths" : "Copy Path") { FinderIntegration.copyPath(paths.joined(separator: "\n")) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(paths.isEmpty)

            Divider()

            Button("Edit…") { if let share { model.pendingRoute = .editShare(share.id) } }
                .keyboardShortcut("e")
                .disabled(share == nil)
            Button("Change Password…") { if let share { model.pendingRoute = .changeCredentials(share.id) } }
                .disabled(share == nil)
            Button("Run Speed Test…") { if let share { model.pendingRoute = .speedTest(share.id) } }
                .disabled(rt?.state != .mounted)

            Divider()

            Button("Mount All") { model.coordinator.mountAll() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Unmount All") { Task { await model.coordinator.unmountAll() } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Berth Help") { NSWorkspace.shared.open(Links.help) }
            Button("Welcome Tour") { openWindow(id: WindowID.welcome) }
            Divider()
            Button("Show Log File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([EventLog.logFileURL]) }
            Button("Copy Diagnostics Report") { Diagnostics.copyReport(model: model) }
            Divider()
            Button("Report an Issue…") { NSWorkspace.shared.open(Links.issues) }
        }
    }
}

enum Links {
    static let website = URL(string: "https://github.com/gergogyulai/berth")!
    static let help = URL(string: "https://github.com/gergogyulai/berth#readme")!
    static let issues = URL(string: "https://github.com/gergogyulai/berth/issues/new")!
}

struct SelectedSharesKey: FocusedValueKey {
    typealias Value = Set<UUID>
}

extension FocusedValues {
    var selectedShareIDs: Set<UUID>? {
        get { self[SelectedSharesKey.self] }
        set { self[SelectedSharesKey.self] = newValue }
    }
}
