import SwiftUI
import BerthKit

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DefaultsKey.hasCompletedWelcome) private var hasCompletedWelcome = false
    @State private var launchAtLogin = LoginItem.shared.isEnabled
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
                .padding(.top, 36)

            Text("Welcome to Berth")
                .font(.largeTitle.bold())
                .padding(.top, 16)
            Text("Your network shares, mounted and kept that way.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "arrow.triangle.2.circlepath", color: .blue, title: "Reconnects on its own",
                        text: "After sleep, network switches and VPN changes.")
                Feature(symbol: "point.3.filled.connected.trianglepath.dotted", color: .purple, title: "Home or away",
                        text: "Local at home, Tailscale everywhere else.")
                Feature(symbol: "key.fill", color: .gray, title: "Private",
                        text: "Passwords stay in your Keychain.")
                Feature(symbol: "menubar.rectangle", color: .green, title: "Always at hand",
                        text: "In the menu bar, on a hot key and in Shortcuts.")
            }
            .padding(.horizontal, 56)
            .padding(.top, 28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            Spacer(minLength: 24)

            Toggle("Open at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, on in LoginItem.shared.setEnabled(on) }

            HStack(spacing: 12) {
                Button("Import from Finder…") { finish(route: .importShares) }
                    .controlSize(.large)
                Button("Add a Share") { finish(route: .newShare(prefill: nil)) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)

            Button("Not Now") { finish(route: nil) }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 12)
                .padding(.bottom, 26)
        }
        .frame(width: 480, height: 580)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.35).delay(0.1)) { appeared = true }
        }
    }

    private func finish(route: AppModel.Route?) {
        hasCompletedWelcome = true
        dismissWindow(id: WindowID.welcome)
        if let route { model.pendingRoute = route }
        openWindow(id: WindowID.main)
    }
}

private struct Feature: View {
    var symbol: String
    var color: Color
    var title: LocalizedStringKey
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
