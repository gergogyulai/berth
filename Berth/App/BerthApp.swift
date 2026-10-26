import SwiftUI
import BerthKit

@main
struct BerthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true
    private let model = AppModel.shared

    var body: some Scene {
        Window("Berth", id: WindowID.main) {
            MainWindow()
                .environment(model)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 920, height: 580)
        .windowToolbarStyle(.unified)
        .commands { BerthCommands(model: model) }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Connection Log", id: WindowID.log) {
            LogView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 300)
        }
        .defaultSize(width: 760, height: 480)
        .keyboardShortcut("l", modifiers: [.command, .option])
        .restorationBehavior(.disabled)

        Window("Welcome to Berth", id: WindowID.welcome) {
            WelcomeView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

enum DefaultsKey {
    static let showMenuBarIcon = "ShowMenuBarIcon"
    static let showDockIcon = "ShowDockIcon"
    static let hasCompletedWelcome = "HasCompletedWelcome"
    static let menuBarShowsCount = "MenuBarShowsMountedCount"
    static let confirmBeforeQuit = "ConfirmUnmountBeforeQuit"
}

/// The menu bar icon reflects the overall state at a glance.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(DefaultsKey.menuBarShowsCount) private var showCount = false

    var body: some View {
        let aggregate = model.coordinator.aggregate
        HStack(spacing: 3) {
            Image(systemName: symbol(for: aggregate))
            if showCount, model.coordinator.mountedCount > 0 {
                Text("\(model.coordinator.mountedCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibility(for: aggregate))
        .onAppear {
            OpenWindowBridge.shared.openWindow = openWindow
            OpenWindowBridge.shared.openSettings = openSettings
        }
    }

    private func symbol(for state: ShareCoordinator.AggregateState) -> String {
        switch state {
        case .idle: "externaldrive.connected.to.line.below"
        case .mounted: "externaldrive.fill.badge.checkmark"
        case .busy: "externaldrive.badge.timemachine"
        case .problem: "externaldrive.badge.exclamationmark"
        }
    }

    private func accessibility(for state: ShareCoordinator.AggregateState) -> String {
        switch state {
        case .idle: String(localized: "Berth: nothing mounted")
        case .mounted: String(localized: "Berth: \(model.coordinator.mountedCount) mounted")
        case .busy: String(localized: "Berth: connecting")
        case .problem: String(localized: "Berth: needs attention")
        }
    }
}
