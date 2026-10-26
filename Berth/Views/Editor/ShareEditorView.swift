import SwiftUI
import BerthKit

struct ShareEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShareDraft
    var onSave: (Share) -> Void

    @State private var error: String?
    @State private var hasStoredPassword: Bool
    @State private var showIconPicker = false
    @State private var testResults: [UUID: Reachability.Result] = [:]
    @State private var isTesting = false
    @FocusState private var focusedField: Field?

    // Less common settings live in collapsed sections; they start open when they're in use.
    @State private var showOptions: Bool
    @State private var showWake: Bool
    @State private var showPerformance: Bool
    @State private var showNotes: Bool

    enum Field { case name, host, share, user, password }
    enum Area { case main, options, wake }

    init(draft: ShareDraft, onSave: @escaping (Share) -> Void) {
        _draft = State(initialValue: draft)
        _hasStoredPassword = State(initialValue: !draft.isNew && Keychain.hasPassword(for: draft.share.id))
        _showOptions = State(initialValue: draft.share.mountLocation.customPath != nil)
        _showWake = State(initialValue: draft.share.wakeOnLAN.enabled)
        _showPerformance = State(initialValue: draft.share.options.preset != nil)
        _showNotes = State(initialValue: !draft.share.notes.isEmpty)
        self.onSave = onSave
    }

    private var share: Binding<Share> { $draft.share }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                headerSection
                serverSection
                signInSection
                mountingSection
                optionsSection
                wakeSection
                performanceSection
                notesSection
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 520, height: 620)
        .onAppear { if draft.isNew { focusedField = .host } }
        .onChange(of: draft.share) { if error != nil { withAnimation { error = nil } } }
        .onChange(of: draft.password) { if error != nil { withAnimation { error = nil } } }
    }

    // MARK: Header / footer

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    showIconPicker = true
                } label: {
                    ShareIconView(icon: draft.share.icon, size: 44)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Change Icon")
                .accessibilityLabel("Change Icon")
                .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                    IconPicker(icon: share.icon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: share.displayName, prompt: Text(draft.share.shareName.isEmpty ? String(localized: "Name") : draft.share.shareName))
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .labelsHidden()
                        .focused($focusedField, equals: .name)
                    Text(draft.share.shareName.isEmpty ? String(localized: "New Share") : draft.share.locationSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await testConnection() }
            } label: {
                Text("Test Connection")
                    .opacity(isTesting ? 0 : 1)
                    .overlay { if isTesting { ProgressView().controlSize(.small) } }
            }
            .disabled(isTesting || !draft.share.addresses.contains { !$0.trimmedHost.isEmpty })

            Group {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if !testResults.isEmpty {
                    testSummary
                }
            }
            .font(.callout)
            .lineLimit(2)
            .transition(.opacity)

            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(draft.isNew ? "Add" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var testSummary: some View {
        let reachable = testResults.values.filter(\.isReachable).count
        return Label(
            reachable > 0 ? "\(reachable) of \(testResults.count) reachable" : "No address answered",
            systemImage: reachable > 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(reachable > 0 ? .green : .orange)
    }

    // MARK: Essentials

    private var serverSection: some View {
        Section {
            AddressListEditor(addresses: share.addresses, results: testResults)
            TextField("Share", text: share.shareName, prompt: Text("Media"))
                .focused($focusedField, equals: .share)
        } header: {
            Text("Server")
        } footer: {
            Text("Addresses are tried in order. Put the local one first and a Tailscale one after it.")
                .foregroundStyle(.secondary)
        }
    }

    private var signInSection: some View {
        Section("Sign In") {
            Picker("Connect As", selection: share.auth) {
                ForEach(AuthMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }

            if draft.share.auth == .registered {
                TextField("Name", text: share.username, prompt: Text("Required"))
                    .textContentType(.username)
                    .focused($focusedField, equals: .user)
                SecureField("Password", text: $draft.password,
                            prompt: Text(hasStoredPassword ? String(localized: "Saved in Keychain") : String(localized: "Required")))
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                TextField("Domain", text: share.domain, prompt: Text("Optional"))
            }
        }
    }

    private var mountingSection: some View {
        Section {
            Picker("Mount Automatically", selection: share.autoMount) {
                ForEach(AutoMount.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Networks", selection: share.networkRule.mode) {
                ForEach(NetworkRule.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if draft.share.networkRule.mode == .trustedOnly || draft.share.networkRule.mode == .trustedOrTailscale {
                Toggle("Use home networks from Settings", isOn: Binding(
                    get: { draft.share.networkRule.trustedNetworks.isEmpty },
                    set: { useGlobal in
                        draft.share.networkRule.trustedNetworks = useGlobal ? [] : (model.config.homeNetworks.ssids.isEmpty
                            ? [model.network.snapshot.ssid].compactMap { $0 } : model.config.homeNetworks.ssids)
                    }
                ))
                if !draft.share.networkRule.trustedNetworks.isEmpty {
                    SSIDListEditor(ssids: share.networkRule.trustedNetworks)
                }
            }
            if !model.config.groups.isEmpty {
                Picker("Group", selection: share.groupID) {
                    Text("None").tag(UUID?.none)
                    Divider()
                    ForEach(model.config.groups) { group in
                        Label(group.name, systemImage: group.symbol).tag(UUID?.some(group.id))
                    }
                }
            }
        } header: {
            Text("Mounting")
        } footer: {
            Text(mountingFooter).foregroundStyle(.secondary)
        }
    }

    private var mountingFooter: String {
        switch draft.share.networkRule.mode {
        case .anywhere: draft.share.autoMount.detail
        case .trustedOnly:
            model.config.homeNetworks.ssids.isEmpty && draft.share.networkRule.trustedNetworks.isEmpty
                ? String(localized: "Add your home networks in Settings › Networks.")
                : String(localized: "Mounts on your home networks and unmounts cleanly when you leave.")
        case .trustedOrTailscale: String(localized: "At home every address is tried. Elsewhere only Tailscale addresses are used.")
        case .tailscaleOnly: String(localized: "Only Tailscale addresses (100.x, *.ts.net) are used.")
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        Section("Options", isExpanded: $showOptions) {
            Picker("Mount Point", selection: Binding(
                get: { draft.share.mountLocation.customPath == nil ? 0 : 1 },
                set: { draft.share.mountLocation = $0 == 0 ? .automatic : .custom(path: draft.share.mountLocation.customPath ?? defaultCustomPath) }
            )) {
                Text("Automatic").tag(0)
                Text("Custom Folder").tag(1)
            }
            if let path = draft.share.mountLocation.customPath {
                LabeledContent {
                    HStack {
                        TextField("Folder", text: Binding(get: { path }, set: { draft.share.mountLocation = .custom(path: $0) }))
                            .labelsHidden()
                            .monospaced()
                        Button("Choose…") { chooseMountFolder() }
                    }
                } label: {
                    Text("Folder")
                    Text("Must be empty. Created if needed.")
                }
            }
            Toggle("Read-only", isOn: share.options.readOnly)
            Toggle(isOn: share.options.softMount) {
                Text("Soft mount")
                Text("Apps get an error instead of hanging when the server goes away.")
            }
            Toggle("Hide from Finder sidebar and Desktop", isOn: share.options.hideFromFinder)
            Toggle("Add to Finder sidebar while mounted", isOn: share.pinToSidebar)
            Toggle(isOn: share.applyVolumeIcon) {
                Text("Use icon as volume icon")
                Text("Writes .VolumeIcon.icns to the share.")
            }
            Toggle(isOn: share.options.forceNewSession) {
                Text("Use a separate session")
                Text("Lets you mount two shares on one server as different users.")
            }
            Toggle("Ignore set-user-ID and device files", isOn: share.options.noSetUID)
        }
    }

    private var wakeSection: some View {
        Section("Wake-on-LAN", isExpanded: $showWake) {
            Toggle(isOn: share.wakeOnLAN.enabled) {
                Text("Wake the server before connecting")
                Text("For servers that sleep. Sent when no address answers.")
            }
            if draft.share.wakeOnLAN.enabled {
                TextField("MAC Address", text: share.wakeOnLAN.macAddress, prompt: Text(verbatim: "aa:bb:cc:dd:ee:ff"))
                    .monospaced()
                TextField("Broadcast Address", text: share.wakeOnLAN.broadcastAddress, prompt: Text(verbatim: "255.255.255.255"))
                    .monospaced()
                Picker("Wait up to", selection: share.wakeOnLAN.wakeTimeout) {
                    ForEach(Set([15.0, 30.0, 45.0, 60.0, 120.0, 300.0, draft.share.wakeOnLAN.wakeTimeout]).sorted(), id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))).tag(seconds)
                    }
                }
                HStack {
                    if !draft.share.wakeOnLAN.macAddress.isEmpty && !draft.share.wakeOnLAN.isUsable {
                        Label("Not a valid MAC address", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Send Wake Packet") {
                        do {
                            try WakeOnLAN.wake(mac: draft.share.wakeOnLAN.macAddress, broadcast: draft.share.wakeOnLAN.broadcastAddress)
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(!draft.share.wakeOnLAN.isUsable)
                }
            }
        }
    }

    private var performanceSection: some View {
        Section("Performance", isExpanded: $showPerformance) {
            Picker("Preset", selection: share.options.preset) {
                Text("System Default").tag(PerformancePreset?.none)
                Divider()
                ForEach(PerformancePreset.allCases) { preset in
                    Label(preset.title, systemImage: preset.symbol).tag(PerformancePreset?.some(preset))
                }
            }
            if let preset = draft.share.options.preset {
                Text(preset.summary).foregroundStyle(.secondary)
            }
            HStack {
                Text("Applies to the whole server from the next mount.").foregroundStyle(.secondary)
                Spacer()
                Button("SMB Settings…") { model.showSettings(tab: .smb) }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private var notesSection: some View {
        Section("Notes", isExpanded: $showNotes) {
            TextEditor(text: share.notes)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
        }
    }

    private var defaultCustomPath: String {
        let name = draft.share.name.replacingOccurrences(of: "/", with: "-")
        return "~/Shares/\(name)"
    }

    private func chooseMountFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use Folder")
        panel.message = String(localized: "Choose an empty folder to mount “\(draft.share.name)” into.")
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var path = url.path
            if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
            draft.share.mountLocation = .custom(path: path)
        }
    }

    // MARK: Actions

    private func testConnection() async {
        isTesting = true
        error = nil
        testResults = [:]
        let results = await model.coordinator.testAddresses(of: draft.share)
        withAnimation {
            for (address, result) in results { testResults[address.id] = result }
            isTesting = false
        }
    }

    private func save() {
        var s = draft.share
        s.displayName = s.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        s.shareName = s.shareName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        s.username = s.username.trimmingCharacters(in: .whitespaces)
        s.addresses = s.addresses.filter { !$0.trimmedHost.isEmpty }.map { var a = $0; a.host = a.trimmedHost; return a }

        // Accept a pasted smb:// URL in the host field.
        if s.shareName.isEmpty, let first = draft.share.addresses.first, let parsed = SMBURL.parse(first.host.hasPrefix("smb://") ? first.host : "smb://\(first.host)"),
           !parsed.share.isEmpty {
            s.addresses[0].host = parsed.host
            s.addresses[0].port = parsed.port
            s.shareName = parsed.share
            if s.username.isEmpty { s.username = parsed.username }
            if s.domain.isEmpty { s.domain = parsed.domain }
        }

        guard !s.addresses.isEmpty else { return fail("Enter the server’s address.", field: .host) }
        guard !s.shareName.isEmpty else { return fail("Enter the name of the share.", field: .share) }
        if s.auth == .registered {
            guard !s.username.isEmpty else { return fail("Enter a user name, or connect as Guest.", field: .user) }
            guard !draft.password.isEmpty || hasStoredPassword else { return fail("Enter the password.", field: .password) }
        }
        if s.wakeOnLAN.enabled && !s.wakeOnLAN.isUsable { return fail("The Wake-on-LAN MAC address isn’t valid.", area: .wake) }
        if let path = s.mountLocation.customPath, !path.hasPrefix("/") && !path.hasPrefix("~") {
            return fail("The mount folder must be a full path.", area: .options)
        }

        do {
            try model.save(s, password: draft.password.isEmpty ? nil : draft.password)
            onSave(s)
            dismiss()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String, field: Field? = nil, area: Area = .main) {
        withAnimation {
            error = message
            if area == .options { showOptions = true }
            if area == .wake { showWake = true }
        }
        focusedField = field
        NSSound.beep()
    }
}

/// Ordered list of server addresses with kind, port, reorder and discovery.
struct AddressListEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var addresses: [ServerAddress]
    var results: [UUID: Reachability.Result]

    var body: some View {
        ForEach($addresses) { $address in
            let index = addresses.firstIndex { $0.id == address.id } ?? 0
            HStack(spacing: 6) {
                TextField(index == 0 ? "Address" : "Fallback", text: $address.host,
                          prompt: Text(index == 0 ? "nas.local or smb://…" : "nas.tailnet.ts.net"))
                if let result = results[address.id] {
                    Image(systemName: result.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.isReachable ? .green : .orange)
                        .help(result.latency.map { formatLatency($0.inMilliseconds) } ?? "Not reachable")
                }
                kindBadge(address)
                Menu {
                    Picker("Network", selection: $address.kind) {
                        ForEach(AddressKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Custom Port…") { promptPort(for: address.id) }
                    if address.port != nil { Button("Use Default Port (445)") { address.port = nil } }
                    Divider()
                    Button("Move Up") { move(address.id, by: -1) }.disabled(index == 0)
                    Button("Move Down") { move(address.id, by: 1) }.disabled(index == addresses.count - 1)
                    Divider()
                    Button("Remove", role: .destructive) { addresses.removeAll { $0.id == address.id } }
                        .disabled(addresses.count == 1)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        HStack {
            Button("Add Fallback Address") {
                addresses.append(ServerAddress())
            }
            .buttonStyle(.link)
            Spacer()
            DiscoverMenu { host in
                if let i = addresses.firstIndex(where: { $0.trimmedHost.isEmpty }) {
                    addresses[i].host = host
                } else {
                    addresses.append(ServerAddress(host: host))
                }
            }
        }
    }

    private func kindBadge(_ address: ServerAddress) -> some View {
        let kind = address.trimmedHost.isEmpty ? nil : address.resolvedKind
        return Group {
            // Only Tailscale is worth calling out; local is the default.
            if kind == .tailscale {
                Text(verbatim: "Tailscale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(address.kind == .automatic ? "Detected automatically" : "Set manually")
            }
            if let port = address.port {
                Text(":\(port)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let i = addresses.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard addresses.indices.contains(j) else { return }
        addresses.swapAt(i, j)
    }

    private func promptPort(for id: UUID) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Custom SMB Port")
        alert.informativeText = String(localized: "Only needed when the server listens on a port other than 445.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "445"
        if let current = addresses.first(where: { $0.id == id })?.port { field.stringValue = "\(current)" }
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn, let i = addresses.firstIndex(where: { $0.id == id }) {
            let port = Int(field.stringValue)
            addresses[i].port = (port == nil || port == 445) ? nil : port.map { min(max($0, 1), 65535) }
        }
    }
}

/// Lists Bonjour-advertised SMB servers.
struct DiscoverMenu: View {
    @Environment(AppModel.self) private var model
    var onPick: (String) -> Void

    var body: some View {
        Menu {
            if model.bonjour.servers.isEmpty {
                Text(model.bonjour.isBrowsing ? "Searching…" : "No servers found")
            }
            ForEach(model.bonjour.servers) { server in
                Button {
                    Task {
                        let host = await BonjourBrowser.resolveHost(serviceName: server.name) ?? server.host
                        onPick(host)
                    }
                } label: {
                    Label(server.name, systemImage: server.model?.lowercased().contains("mac") == true ? "desktopcomputer" : "externaldrive.connected.to.line.below")
                }
            }
        } label: {
            Label("Nearby", systemImage: "bonjour")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { model.bonjour.start() }
        .help("Servers advertised on this network")
    }
}

/// Editable list of Wi-Fi names.
struct SSIDListEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var ssids: [String]
    @State private var newSSID = ""

    var body: some View {
        ForEach(ssids, id: \.self) { ssid in
            HStack {
                Image(systemName: "wifi").foregroundStyle(.secondary)
                Text(ssid)
                if ssid == model.network.snapshot.ssid {
                    Text("Current").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button {
                    ssids.removeAll { $0 == ssid }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        HStack {
            TextField("Network Name", text: $newSSID, prompt: Text("Wi-Fi name"))
                .onSubmit(add)
            Button("Add", action: add).disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
            if let current = model.network.snapshot.ssid, !ssids.contains(current) {
                Button("Add “\(current)”") { ssids.append(current) }
            }
        }
        if model.network.snapshot.usesWiFi && model.network.snapshot.ssid == nil {
            LabeledContent {
                Button("Allow…") { model.network.requestLocationAccess() }
            } label: {
                Text("Wi-Fi name unavailable")
                Text("Berth needs Location access to see which network you’re on.")
            }
        }
    }

    private func add() {
        let name = newSSID.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !ssids.contains(name) else { return }
        ssids.append(name)
        newSSID = ""
    }
}
