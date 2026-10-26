import SwiftUI
import BerthKit

/// Imports shares from what's mounted now, Finder's recent/favorite servers, and Bonjour.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with a prefilled draft when the user picks a Bonjour server (needs share name and sign-in).
    var onConfigure: (ShareDraft) -> Void

    @State private var candidates: [ShareImporter.Candidate] = []
    @State private var chosen = Set<String>()
    @State private var loading = true
    @State private var importPasswords = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Shares").font(.title2.weight(.semibold))
                Text("Pick the shares you already use. You can fine-tune each one afterwards.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            List {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Looking for shares…").foregroundStyle(.secondary) }
                }
                ForEach([ShareImporter.Candidate.Source.mounted, .finder], id: \.self) { source in
                    let items = candidates.filter { $0.source == source }
                    if !items.isEmpty {
                        Section(source.rawValue) {
                            ForEach(items) { candidate in
                                Toggle(isOn: Binding(
                                    get: { chosen.contains(candidate.id) },
                                    set: { if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) } }
                                )) {
                                    HStack(spacing: 10) {
                                        ShareIconView(icon: candidate.makeShare().icon, size: 26)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(candidate.title)
                                            Text(candidate.subtitle).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                Section {
                    if model.bonjour.servers.isEmpty {
                        Text(model.bonjour.isBrowsing ? "Searching the local network…" : "No servers found")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.bonjour.servers) { server in
                        HStack {
                            Image(systemName: "externaldrive.connected.to.line.below")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name)
                                Text(server.model ?? server.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Set Up…") {
                                Task {
                                    let host = await BonjourBrowser.resolveHost(serviceName: server.name) ?? server.host
                                    var share = Share(displayName: server.name, addresses: [ServerAddress(host: host)])
                                    share.icon = ShareImporter.Candidate.guessIcon(for: server.name)
                                    onConfigure(ShareDraft(share: share, password: "", isNew: true))
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Text(ShareImporter.Candidate.Source.bonjour.rawValue)
                }
                if !loading && candidates.isEmpty {
                    Text("Nothing mounted right now, and Finder has no recent SMB servers.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 300)

            HStack {
                Toggle("Look up passwords Finder saved", isOn: $importPasswords)
                    .toggleStyle(.checkbox)
                    .help("macOS may ask to allow access to each Keychain item.")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Import" : "Import \(chosen.count)") { importChosen() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 560)
        .task {
            model.bonjour.start()
            let existing = model.config.shares
            let found = await Task.detached { ShareImporter.candidates(excluding: existing) }.value
            candidates = found
            chosen = Set(found.filter { $0.source == .mounted }.map(\.id))
            loading = false
        }
    }

    private func importChosen() {
        var added: [UUID] = []
        for candidate in candidates where chosen.contains(candidate.id) {
            let share = candidate.makeShare()
            var password: String?
            if importPasswords, share.auth == .registered {
                password = Keychain.finderPassword(server: candidate.host, account: candidate.username)
            }
            try? model.save(share, password: password)
            added.append(share.id)
        }
        model.coordinator.syncRuntimes()
        model.log.add(.info, "Imported \(added.count) shares")
        if let first = added.first { model.pendingRoute = .select(first) }
        dismiss()
    }
}
