import SwiftUI
import BerthKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    /// The group whose name is being edited in place.
    @Binding var editingGroup: UUID?
    var newGroup: () -> Void

    @State private var editingName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let problems = model.config.shares.filter { model.runtime($0.id).state.isProblem }.count
        List(selection: $selection) {
            Label("All Shares", systemImage: "externaldrive.connected.to.line.below")
                .tag(SidebarItem.all)
            // Like a smart mailbox: only there while something needs you (or while you're looking at it).
            if problems > 0 || selection == .attention {
                Label("Needs Attention", systemImage: "exclamationmark.triangle")
                    .badge(problems)
                    .tag(SidebarItem.attention)
            }

            if !model.config.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.config.groups) { groupRow($0) }
                        .onMove { from, to in model.store.update { $0.groups.move(fromOffsets: from, toOffset: to) } }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if case .group(let id)? = items.first, let group = model.config.group(id: id) {
                groupMenu(group)
            } else if items.isEmpty {
                Button("New Group") { newGroup() }
            }
        }
        // Return renames the selected group, as in Finder.
        .onKeyPress(.return) {
            guard editingGroup == nil, case .group(let id)? = selection else { return .ignored }
            editingGroup = id
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { NetworkStatusFooter() }
        .onChange(of: editingGroup, initial: true) { _, id in
            guard let id, let group = model.config.group(id: id) else { return }
            editingName = group.name
            DispatchQueue.main.async { nameFocused = true }
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitRename() }
        }
    }

    private func groupRow(_ group: ShareGroup) -> some View {
        Label {
            if editingGroup == group.id {
                TextField("Group Name", text: $editingName)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editingGroup = nil }
            } else {
                Text(verbatim: group.name)
            }
        } icon: {
            Image(systemName: group.symbol)
        }
        .tag(SidebarItem.group(group.id))
        // Dropping shares (dragged from the list as UUID strings) onto a group moves them there.
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids { model.move(id, toGroup: group.id) }
            return !ids.isEmpty
        }
    }

    private func commitRename() {
        guard let id = editingGroup else { return }
        editingGroup = nil
        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.store.update { config in
            if let i = config.groups.firstIndex(where: { $0.id == id }) { config.groups[i].name = name }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: ShareGroup) -> some View {
        Button("Mount All in “\(group.name)”") { model.coordinator.mountAll(groupID: group.id, onlyGroup: true) }
        Button("Unmount All in “\(group.name)”") { Task { await model.coordinator.unmountAll(groupID: group.id, onlyGroup: true) } }
        Divider()
        Button("Rename") { editingGroup = group.id }
        Menu("Icon") {
            Picker("Icon", selection: Binding(
                get: { group.symbol },
                set: { symbol in
                    model.store.update { config in
                        if let i = config.groups.firstIndex(where: { $0.id == group.id }) { config.groups[i].symbol = symbol }
                    }
                }
            )) {
                ForEach(Self.groupSymbols, id: \.self) { Image(systemName: $0).tag($0) }
            }
            .pickerStyle(.palette)
        }
        Divider()
        Button("New Group") { newGroup() }
        Button("Delete Group", role: .destructive) {
            if selection == .group(group.id) { selection = .all }
            model.deleteGroup(group)
        }
    }

    private static let groupSymbols = [
        "folder", "film.stack", "music.note", "photo.stack", "clock.arrow.circlepath", "briefcase",
        "house", "hammer", "archivebox", "gamecontroller", "star", "server.rack",
    ]
}

/// One quiet line at the bottom of the sidebar: where you are and whether Tailscale is up.
struct NetworkStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snap = model.network.snapshot
        Button {
            model.showSettings(tab: .networks)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol(snap))
                    .foregroundStyle(snap.isOnline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .frame(width: 16)
                Text(description(snap))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(snap.summary)
        .accessibilityLabel(snap.summary)
    }

    private func symbol(_ snap: NetworkSnapshot) -> String {
        guard snap.isOnline else { return "wifi.slash" }
        return snap.usesWired ? "cable.connector" : "wifi"
    }

    private func description(_ snap: NetworkSnapshot) -> String {
        guard snap.isOnline else { return String(localized: "Offline") }
        var parts: [String] = []
        if let ssid = snap.ssid {
            parts.append(ssid)
        } else if snap.usesWired {
            parts.append(String(localized: "Ethernet"))
        } else {
            parts.append(String(localized: "Connected"))
        }
        if snap.tailscale.isUp { parts.append("Tailscale") }
        if snap.isConstrained { parts.append(String(localized: "Low Data")) } else if snap.isExpensive { parts.append(String(localized: "Metered")) }
        return parts.joined(separator: " · ")
    }
}
