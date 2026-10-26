import AppKit
import SwiftUI
import BerthKit
import os

/// App-wide state and services. One instance, shared by the UI, AppleScript, App Intents and the
/// CLI socket.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store: ConfigStore
    let network: NetworkMonitor
    let log: EventLog
    let coordinator: ShareCoordinator
    let notifications = NotificationManager()
    let hotKeys = HotKeyManager()
    let bonjour = BonjourBrowser()

    /// Requests from places without direct access to the main window (menu bar, notifications,
    /// Shortcuts) for the main window to present something.
    var pendingRoute: Route?

    /// Speed test results, kept for the session.
    var speedTestResults: [UUID: SpeedTest.Result] = [:]

    /// The share the Connection Log window should filter to when it next opens.
    var logShareFilter: UUID?

    enum Route: Equatable {
        case newShare(prefill: Share?)
        case newGroup
        case editShare(UUID)
        case changeCredentials(UUID)
        case importShares
        case speedTest(UUID)
        case select(UUID)
    }

    @ObservationIgnored private var ipcServer: IPCServer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let logger = Logger(subsystem: "app.berth", category: "app")

    private init() {
        store = ConfigStore()
        network = NetworkMonitor()
        log = EventLog()
        coordinator = ShareCoordinator(store: store, network: network, log: log)
    }

    var config: Configuration { store.config }

    func start() {
        guard !started else { return }
        started = true

        if let error = store.lastError { log.add(.error, error) }

        coordinator.onEvent = { [weak self] event in self?.notifications.handle(event, preferences: self?.config.preferences ?? Preferences()) }
        coordinator.postMountHook = { share, path in await FinderIntegration.didMount(share, at: path) }
        coordinator.preUnmountHook = { share, path in FinderIntegration.willUnmount(share, at: path) }
        coordinator.start()

        notifications.setUp()
        notifications.onAction = { [weak self] action, shareID in self?.handleNotificationAction(action, shareID: shareID) }

        applyHotKeys()
        hotKeys.onTrigger = { [weak self] action in
            guard let self else { return }
            switch action {
            case .mountAll: coordinator.mountAll()
            case .unmountAll: Task { await self.coordinator.unmountAll() }
            }
        }

        startIPC()
    }

    func stop() {
        coordinator.stop()
        ipcServer?.stop()
        store.saveNow()
    }

    func applyHotKeys() {
        hotKeys.register(.mountAll, hotKey: config.preferences.mountAllHotKey)
        hotKeys.register(.unmountAll, hotKey: config.preferences.unmountAllHotKey)
    }

    // MARK: Convenience

    func runtime(_ id: UUID) -> ShareRuntime { coordinator.runtime(for: id) }

    func group(for share: Share) -> ShareGroup? { config.group(id: share.groupID) }

    /// Save a share created or edited in the editor, including its password.
    func save(_ share: Share, password: String?) throws {
        let isNew = config.share(id: share.id) == nil
        if share.auth == .registered, let password, !password.isEmpty {
            try Keychain.setPassword(password, for: share.id, label: share.name, server: share.primaryHost, username: share.username)
        } else if share.auth != .registered {
            Keychain.deletePassword(for: share.id)
        }
        store.upsert(share)
        if let preset = share.options.preset { try? NSMBConfEditor.apply(preset, toHost: share.primaryHost) }
        coordinator.shareDidChange(share.id)
        log.add(.info, isNew ? "Share added" : "Share updated", share: share)
    }

    func duplicate(_ share: Share) {
        var copy = share
        copy.id = UUID()
        copy.displayName = "\(share.name) Copy"
        if let password = Keychain.password(for: share.id) {
            try? Keychain.setPassword(password, for: copy.id, label: copy.name, server: copy.primaryHost, username: copy.username)
        }
        if let index = config.shares.firstIndex(where: { $0.id == share.id }) {
            store.update { $0.shares.insert(copy, at: index + 1) }
        } else {
            store.upsert(copy)
        }
        coordinator.syncRuntimes()
        pendingRoute = .select(copy.id)
    }

    func addGroup(named name: String, symbol: String = "folder") -> ShareGroup {
        let group = ShareGroup(name: name, symbol: symbol)
        store.update { $0.groups.append(group) }
        return group
    }

    func deleteGroup(_ group: ShareGroup) {
        store.update { config in
            config.groups.removeAll { $0.id == group.id }
            for i in config.shares.indices where config.shares[i].groupID == group.id { config.shares[i].groupID = nil }
        }
    }

    func move(_ shareID: UUID, toGroup groupID: UUID?) {
        store.update { config in
            if let i = config.shares.firstIndex(where: { $0.id == shareID }) { config.shares[i].groupID = groupID }
        }
    }

    // MARK: Windows

    /// Brings the main window forward (from the menu bar, a notification, a hot key…).
    func showMainWindow(route: Route? = nil) {
        if let route { pendingRoute = route }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            OpenWindowBridge.shared.open(WindowID.main)
        }
    }

    func showLog(for shareID: UUID? = nil) {
        logShareFilter = shareID
        OpenWindowBridge.shared.open(WindowID.log)
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.defaultsKey) }
        NSApp.activate()
        OpenWindowBridge.shared.openSettings?()
    }

    private func handleNotificationAction(_ action: NotificationManager.Action, shareID: UUID?) {
        switch action {
        case .reconnect:
            if let shareID { coordinator.reconnect(shareID) }
        case .updatePassword:
            if let shareID { showMainWindow(route: .changeCredentials(shareID)) }
        case .open:
            if let shareID { showMainWindow(route: .select(shareID)) } else { showMainWindow() }
        case .reveal:
            if let shareID, let path = runtime(shareID).mountPoint { FinderIntegration.reveal(path) }
        }
    }

    // MARK: IPC

    private func startIPC() {
        let server = IPCServer { request in
            await IPCHandler.handle(request)
        }
        do {
            try server.start()
            ipcServer = server
        } catch {
            log.add(.warning, "Command-line socket unavailable: \(error.localizedDescription)")
        }
    }
}

enum WindowID {
    static let main = "main"
    static let welcome = "welcome"
    static let log = "log"
}

/// Lets non-view code open SwiftUI windows. The `openWindow` action is captured from a view
/// that is always alive (the menu bar content / app commands).
@MainActor
final class OpenWindowBridge {
    static let shared = OpenWindowBridge()
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?

    func open(_ id: String) {
        NSApp.activate()
        openWindow?(id: id)
    }
}
