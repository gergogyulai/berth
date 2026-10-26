import AppKit
import SwiftUI
import BerthKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel { AppModel.shared }
    private var observers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.showMenuBarIcon: true,
            DefaultsKey.showDockIcon: true,
            DefaultsKey.confirmBeforeQuit: false,
        ])
        // Launch with the Dock icon (a window is about to open); it goes away with the last window.
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()

        // The Dock icon follows the windows: it appears while one is open and goes away with the
        // last one, leaving Berth in the menu bar.
        let center = NotificationCenter.default
        for name in [UserDefaults.didChangeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Deferred so a closing window is gone by the time we count.
                DispatchQueue.main.async { self?.applyActivationPolicy() }
            })
        }

        let launchedAsLoginItem = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let firstRun = !UserDefaults.standard.bool(forKey: DefaultsKey.hasCompletedWelcome)

        // Started at login or as a menu bar app: stay out of the way. (First run is handled by
        // the main window, which swaps itself for the welcome window.)
        if !firstRun && (launchedAsLoginItem || !showDockIcon) {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue == WindowID.main { window.close() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showMainWindow() }
        return true
    }

    /// Mounts survive quitting — that's the point. Keep the app alive when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.confirmBeforeQuit), model.coordinator.mountedCount > 0 else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Unmount shares before quitting?")
        alert.informativeText = String(localized: "\(model.coordinator.mountedCount) shares are mounted. Without Berth they won’t reconnect automatically.")
        alert.addButton(withTitle: String(localized: "Unmount & Quit"))
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await model.coordinator.unmountAll(force: true)
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for share in model.config.shares {
            let rt = model.runtime(share.id)
            let item = NSMenuItem(title: share.name, action: #selector(toggleShareFromMenu(_:)), keyEquivalent: "")
            item.representedObject = share.id
            item.state = rt.state.isMounted ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        if !model.config.shares.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: String(localized: "Mount All"), action: #selector(mountAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Unmount All"), action: #selector(unmountAll), keyEquivalent: "").target = self
        return menu
    }

    @objc private func toggleShareFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.coordinator.toggle(id)
    }

    @objc private func mountAll() { model.coordinator.mountAll() }
    @objc private func unmountAll() { Task { await model.coordinator.unmountAll() } }

    // MARK: Activation policy

    private var showDockIcon: Bool { UserDefaults.standard.bool(forKey: DefaultsKey.showDockIcon) }
    private var showMenuBarIcon: Bool { UserDefaults.standard.bool(forKey: DefaultsKey.showMenuBarIcon) }

    /// Titled windows the user can see or restore — excludes the status item, menus and alerts.
    private static var userWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is NSPanel) && $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
    }

    /// With the menu bar icon hidden the Dock is the only way back in, so it stays put.
    private func applyActivationPolicy() {
        let wantsDock = showDockIcon && (!showMenuBarIcon || !Self.userWindows.isEmpty)
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Coming back from accessory, the menu bar only switches over once the app re-activates.
        if policy == .regular { NSApp.activate() }
    }

    /// ⌘Q closes the windows and leaves Berth running in the menu bar. Quitting for real happens
    /// from the menu bar menu (or here, when there's no menu bar icon to fall back to).
    static func closeWindowsOrQuit() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.showMenuBarIcon) else { return NSApp.terminate(nil) }
        for window in Self.userWindows { window.close() }
    }

    // MARK: URL scheme — berth://mount/<share>, berth://unmount/<share>, berth://mount-all, berth://open/<share>

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        URLRouter.handle(url)
    }

    // MARK: AppleScript

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        key == "scriptableShares"
    }

    @objc var scriptableShares: [ScriptableShare] {
        model.config.shares.map(ScriptableShare.init)
    }
}

@MainActor
enum URLRouter {
    static func handle(_ url: URL) {
        guard url.scheme == "berth" else { return }
        let model = AppModel.shared
        let target = url.pathComponents.dropFirst().first?.removingPercentEncoding
        let share = target.flatMap { model.config.resolveShare($0) }
        let group = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "group" }?.value
            .flatMap { model.config.resolveGroup($0) }

        switch url.host {
        case "mount": if let share { model.coordinator.mount(share.id) }
        case "unmount": if let share { Task { await model.coordinator.unmount(share.id) } }
        case "toggle": if let share { model.coordinator.toggle(share.id) }
        case "reconnect": if let share { model.coordinator.reconnect(share.id) }
        case "mount-all": model.coordinator.mountAll(groupID: group?.id, onlyGroup: group != nil)
        case "unmount-all": Task { await model.coordinator.unmountAll(groupID: group?.id, onlyGroup: group != nil) }
        case "open":
            if let share {
                if let path = model.runtime(share.id).mountPoint { FinderIntegration.open(path) } else { model.coordinator.mount(share.id) }
            }
        case "add": model.showMainWindow(route: .newShare(prefill: nil))
        #if DEBUG
        case "debug-snapshot": DebugSnapshot.capture(to: url.path.isEmpty || url.path == "/" ? "/tmp" : url.path)
        case "debug-open":
            if let id = target { OpenWindowBridge.shared.open(id) }
        case "debug-settings":
            model.showSettings(tab: target.flatMap(SettingsTab.init(rawValue:)))
        case "debug-route":
            switch target {
            case "new": model.showMainWindow(route: .newShare(prefill: nil))
            case "edit": if let s = model.config.shares.first { model.showMainWindow(route: .editShare(s.id)) }
            case "creds": if let s = model.config.shares.first { model.showMainWindow(route: .changeCredentials(s.id)) }
            case "import": model.showMainWindow(route: .importShares)
            case "log": model.showLog()
            case "select": if let s = model.config.shares.first { model.showMainWindow(route: .select(s.id)) }
            default: break
            }
        #endif
        default: model.showMainWindow(route: share.map { .select($0.id) })
        }
    }
}

#if DEBUG
/// Renders every visible window of the app to PNG (development aid; needs no screen-recording permission).
@MainActor
enum DebugSnapshot {
    static func capture(to directory: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = (window.identifier?.rawValue ?? "window\(index)").replacingOccurrences(of: "/", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/berth-\(name).png"))
        }
    }
}
#endif
