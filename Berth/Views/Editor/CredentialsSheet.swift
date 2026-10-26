import SwiftUI
import BerthKit

/// Change-credentials flow: unmount → update Keychain → remount.
struct CredentialsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let shareID: UUID

    @State private var auth: AuthMode = .registered
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var loaded = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        if let share = model.config.share(id: shareID) {
            let rt = model.runtime(shareID)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        ShareIconView(icon: share.icon, size: 48)
                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(.orange))
                            .offset(x: 6, y: 6)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sign In to “\(share.name)”").font(.title3.weight(.semibold))
                        Text(share.locationSummary).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(20)

                if rt.state == .authFailed, let message = rt.lastError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Form {
                    Picker("Connect as", selection: $auth) {
                        ForEach(AuthMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if auth == .registered {
                        TextField("User Name", text: $username)
                            .textContentType(.username)
                        TextField("Domain", text: $domain, prompt: Text("Optional"))
                        SecureField("Password", text: $password, prompt: Text("New password"))
                            .textContentType(.password)
                            .focused($passwordFocused)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: auth == .registered ? 190 : 80)

                Text(rt.state.isMounted
                     ? "“\(share.name)” will be unmounted, the new credentials saved to your Keychain, and the share mounted again."
                     : "The credentials are saved to your login Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)

                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.top, 6)
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(rt.state.isMounted || rt.wantsMounted || rt.state == .authFailed ? "Save & Reconnect" : "Save") {
                        Task { await save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || (auth == .registered && (username.isEmpty || password.isEmpty)))
                }
                .padding(20)
            }
            .frame(width: 440)
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView().controlSize(.large) } }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                auth = share.auth
                username = share.username
                domain = share.domain
                passwordFocused = true
            }
        }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.coordinator.updateCredentials(shareID, auth: auth, username: username.trimmingCharacters(in: .whitespaces),
                                                          domain: domain.trimmingCharacters(in: .whitespaces),
                                                          password: auth == .registered ? password : nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
