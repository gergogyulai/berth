import SwiftUI
import BerthKit

enum SettingsTab: String, CaseIterable {
    case general, networks, automation, smb, advanced

    static let defaultsKey = "SelectedSettingsTab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.defaultsKey) private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            // Each pane gets a height that fits its content, so the window resizes per tab like
            // other Mac apps instead of scrolling.
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings().frame(height: 700) }
            Tab("Networks", systemImage: "network", value: .networks) { NetworkSettings().frame(height: 540) }
            Tab("Automation", systemImage: "command", value: .automation) { AutomationSettings().frame(height: 560) }
            Tab("SMB", systemImage: "externaldrive.connected.to.line.below", value: .smb) { SMBSettings().frame(height: 640) }
            Tab("Advanced", systemImage: "gearshape.2", value: .advanced) { AdvancedSettings().frame(height: 640) }
        }
        .frame(width: 560)
    }
}

/// A binding into `Preferences` that saves on write.
@MainActor
private func pref<T>(_ model: AppModel, _ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
    Binding(
        get: { model.config.preferences[keyPath: keyPath] },
        set: { value in model.store.update { $0.preferences[keyPath: keyPath] = value } }
    )
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DefaultsKey.showDockIcon) private var showDockIcon = true
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(DefaultsKey.menuBarShowsCount) private var showCount = false
    @AppStorage(DefaultsKey.confirmBeforeQuit) private var confirmBeforeQuit = false
    @State private var syncError: String?
    private let login = LoginItem.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { login.isEnabled || login.needsApproval }, set: { login.setEnabled($0) }))
                if login.needsApproval {
                    LabeledContent {
                        Button("Open Login Items…") { login.openSystemSettings() }
                    } label: {
                        Text("Waiting for approval in System Settings")
                            .foregroundStyle(.orange)
                    }
                }
                if let error = login.lastError {
                    Text(error).foregroundStyle(.red)
                }
                Toggle(isOn: pref(model, \.autoMountEnabled)) {
                    Text("Mount shares automatically")
                    Text("Follows each share’s “Mount Automatically” setting.")
                }
                Toggle("Offer to unmount shares when quitting", isOn: $confirmBeforeQuit)
            }

            Section("Show Berth In") {
                Toggle("Dock", isOn: $showDockIcon)
                    .disabled(!showMenuBarIcon && showDockIcon)
                Toggle("Menu bar", isOn: $showMenuBarIcon)
                    .disabled(!showDockIcon && showMenuBarIcon)
                if showMenuBarIcon {
                    Toggle("Show number of mounted shares", isOn: $showCount)
                }
            }

            Section {
                Toggle("Share mounted", isOn: pref(model, \.notifyOnConnect))
                Toggle("Connection lost", isOn: pref(model, \.notifyOnDisconnect))
                Toggle("Server stopped responding", isOn: pref(model, \.notifyOnStale))
                Toggle("Sign-in failed", isOn: pref(model, \.notifyOnAuthFailure))
            } header: {
                Text("Notify Me When")
            } footer: {
                notificationStatus
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.store.syncEnabled },
                    set: { enabled in
                        do { try model.store.setSyncEnabled(enabled); syncError = nil } catch { syncError = error.localizedDescription }
                    }
                )) {
                    Text("Sync shares with iCloud Drive")
                    Text(ConfigStore.iCloudDriveAvailable
                         ? "Passwords stay in each Mac’s Keychain."
                         : "iCloud Drive is turned off on this Mac.")
                }
                .disabled(!ConfigStore.iCloudDriveAvailable && !model.store.syncEnabled)
                if let syncError { Text(syncError).foregroundStyle(.red) }
                LabeledContent("Configuration") {
                    HStack {
                        Button("Export…") { ConfigTransfer.export(model: model) }
                        Button("Import…") { ConfigTransfer.importConfiguration(model: model) }
                    }
                }
            } header: {
                Text("Sync")
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
        .task { await model.notifications.refreshAuthorization() }
    }

    @ViewBuilder
    private var notificationStatus: some View {
        switch model.notifications.authorization {
        case .denied:
            HStack(spacing: 4) {
                Text("Notifications are turned off for Berth.")
                Button("Open System Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.link)
            }
            .foregroundStyle(.secondary)
        case .notDetermined:
            Button("Allow Notifications…") { Task { await model.notifications.requestAuthorization() } }
                .buttonStyle(.link)
        default:
            EmptyView()
        }
    }
}

// MARK: - Networks

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snap = model.network.snapshot
        Form {
            Section {
                LabeledContent("Network") {
                    if let ssid = snap.ssid {
                        Text(ssid)
                    } else if snap.usesWiFi {
                        Text("Wi-Fi")
                    } else if snap.usesWired {
                        Text("Ethernet")
                    } else {
                        Text(snap.isOnline ? "Connected" : "Offline")
                    }
                }
                LabeledContent("Tailscale") {
                    HStack(spacing: 6) {
                        Circle().fill(snap.tailscale.isUp ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                        Text(snap.tailscale.title)
                    }
                }
            }

            Section {
                SSIDListEditor(ssids: Binding(
                    get: { model.config.homeNetworks.ssids },
                    set: { value in model.store.update { $0.homeNetworks.ssids = value } }
                ))
                Toggle("Treat wired Ethernet as home", isOn: Binding(
                    get: { model.config.homeNetworks.wiredIsHome },
                    set: { value in model.store.update { $0.homeNetworks.wiredIsHome = value } }
                ))
            } header: {
                Text("Home Networks")
            } footer: {
                Text("Used by shares that mount only at home, or switch to Tailscale away from home.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause on hotspots and cellular", isOn: pref(model, \.pauseOnExpensiveNetworks))
                Toggle("Pause in Low Data Mode", isOn: pref(model, \.pauseOnConstrainedNetworks))
                Toggle(isOn: pref(model, \.waitForTailscale)) {
                    Text("Wait for Tailscale instead of retrying")
                    Text("Tailscale-only shares mount the moment the tunnel comes up.")
                }
            } header: {
                Text("Automatic Mounting")
            } footer: {
                Text("Shares you mount yourself always mount.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Automation

private struct AutomationSettings: View {
    @Environment(AppModel.self) private var model
    private let installer = CLIInstaller.shared
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Mount all shares") {
                    HotKeyRecorder(hotKey: hotKeyBinding(\.mountAllHotKey))
                }
                LabeledContent("Unmount all shares") {
                    HotKeyRecorder(hotKey: hotKeyBinding(\.unmountAllHotKey))
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Work in every app.").foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    if installer.isInstalled {
                        Button("Uninstall") { installer.uninstall(); refresh += 1 }
                    } else {
                        Button("Install…") { installer.install(); refresh += 1 }
                    }
                } label: {
                    Text("berth command")
                    Text(installer.isInstalled ? "Installed at \(CLIInstaller.linkPath)" : "Use Berth from Terminal and scripts.")
                }
                .id(refresh)
                if installer.isOtherInstalled {
                    Text("Another “berth” is already installed at \(CLIInstaller.linkPath).").foregroundStyle(.orange)
                }
                if let error = installer.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error).foregroundStyle(.red)
                        Text("To install it yourself, run:").foregroundStyle(.secondary)
                        Text(installer.installCommand).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Command Line")
            } footer: {
                Text(verbatim: "berth list  ·  berth mount nas-media  ·  berth unmount --all")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                LabeledContent("Shortcuts", value: String(localized: "Mount, Unmount, Mount All, Get Status"))
                LabeledContent("AppleScript") {
                    Text(verbatim: "mount share \"Media\"").monospaced().textSelection(.enabled)
                }
                LabeledContent("URL") {
                    Text(verbatim: "berth://mount/nas-media").monospaced().textSelection(.enabled)
                }
            } header: {
                Text("Scripting")
            }
        }
        .formStyle(.grouped)
    }

    private func hotKeyBinding(_ keyPath: WritableKeyPath<Preferences, HotKey?>) -> Binding<HotKey?> {
        Binding(
            get: { model.config.preferences[keyPath: keyPath] },
            set: { value in
                model.store.update { $0.preferences[keyPath: keyPath] = value }
                model.applyHotKeys()
            }
        )
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(FinderIntegration.terminalDefaultsKey) private var terminal = "com.apple.Terminal"

    var body: some View {
        Form {
            Section {
                Picker("Check mounts every", selection: pref(model, \.probeInterval)) {
                    Text("10 seconds").tag(10.0)
                    Text("20 seconds").tag(20.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                }
                Picker("Unresponsive after", selection: pref(model, \.probeTimeout)) {
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("20 seconds").tag(20.0)
                }
                Toggle(isOn: pref(model, \.forceUnmountStale)) {
                    Text("Replace mounts that stop responding")
                    Text("Keeps Finder from hanging on a server that went away.")
                }
                if model.config.preferences.forceUnmountStale {
                    Picker("After", selection: pref(model, \.staleGracePeriod)) {
                        Text("Immediately").tag(0.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                    }
                }
            } header: {
                Text("Health Checks")
            }

            Section {
                Picker("Give up connecting after", selection: pref(model, \.mountTimeout)) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("60 seconds").tag(60.0)
                }
                Picker("Retry at most every", selection: pref(model, \.maxRetryDelay)) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("1 hour").tag(3600.0)
                }
            } header: {
                Text("Retrying")
            } footer: {
                Text("Retries back off from 2 seconds up to this limit. A network change retries right away.")
                    .foregroundStyle(.secondary)
            }

            Section("Sleep") {
                Toggle(isOn: pref(model, \.unmountBeforeSleep)) {
                    Text("Unmount before sleep")
                    Text("Avoids “Server connections interrupted” after wake.")
                }
                Toggle("Mount again after wake", isOn: pref(model, \.remountAfterWake))
                    .disabled(!model.config.preferences.unmountBeforeSleep)
            }

            Section {
                Picker("Open in Terminal uses", selection: $terminal) {
                    ForEach(FinderIntegration.installedTerminals) { Text($0.name).tag($0.bundleID) }
                }
                LabeledContent("Configuration file") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.fileURL]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
