import SwiftUI
import BerthKit

struct ShareListView: View {
    @Environment(AppModel.self) private var model
    var filter: SidebarItem
    var search: String
    @Binding var selection: UUID?
    var actions: ShareActions

    var body: some View {
        let sections = self.sections
        Group {
            if model.config.shares.isEmpty {
                EmptySharesView()
            } else if sections.allSatisfy(\.shares.isEmpty) {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyDescription))
                }
            } else {
                List(selection: $selection) {
                    ForEach(sections, id: \.id) { section in
                        if let title = section.title {
                            Section(title) { rows(section) }
                        } else {
                            rows(section)
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first { ShareContextMenu(shareID: id, actions: actions) }
                } primaryAction: { ids in
                    // Double-click does the obvious thing: open what's mounted, mount what isn't.
                    if let id = ids.first { openOrMount(id) }
                }
                .onDeleteCommand {
                    if let selection { actions.delete(selection) }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationSubtitle(subtitle)
    }

    @ViewBuilder
    private func rows(_ section: ListSection) -> some View {
        ForEach(section.shares) { share in
            ShareRow(share: share, isSelected: selection == share.id)
                .tag(share.id)
                .draggable(share.id.uuidString)
        }
        .onMove(perform: search.isEmpty ? { from, to in move(section, from, to) } : nil)
    }

    private func openOrMount(_ id: UUID) {
        let rt = model.runtime(id)
        if let path = rt.mountPoint, rt.state.isMounted {
            FinderIntegration.open(path)
        } else if !rt.isTrying {
            model.coordinator.mount(id)
        }
    }

    struct ListSection {
        var id: String
        var title: String?
        var shares: [Share]
    }

    private var filtered: [Share] {
        model.config.shares.filter { share in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .attention: model.runtime(share.id).state.isProblem
            case .group(let id): share.groupID == id
            }
            guard matchesFilter else { return false }
            guard !search.isEmpty else { return true }
            let haystack = [share.name, share.shareName, share.username] + share.addresses.map(\.host)
            return haystack.contains { $0.localizedStandardContains(search) }
        }
    }

    private var sections: [ListSection] {
        let shares = filtered
        // Group into sections only in "All Shares", and only when groups exist. Ungrouped shares
        // come first, without a header.
        guard filter == .all, !model.config.groups.isEmpty else {
            return [ListSection(id: "all", title: nil, shares: shares)]
        }
        var result: [ListSection] = []
        let ungrouped = shares.filter { model.config.group(id: $0.groupID) == nil }
        if !ungrouped.isEmpty { result.append(ListSection(id: "none", title: nil, shares: ungrouped)) }
        for group in model.config.groups {
            let members = shares.filter { $0.groupID == group.id }
            if !members.isEmpty { result.append(ListSection(id: group.id.uuidString, title: group.name, shares: members)) }
        }
        return result
    }

    /// Translates a move within a (filtered) section into the global share order.
    private func move(_ section: ListSection, _ source: IndexSet, _ destination: Int) {
        let all = model.config.shares
        let globalSource = IndexSet(source.compactMap { i in all.firstIndex { $0.id == section.shares[i].id } })
        let globalDestination: Int
        if destination < section.shares.count {
            globalDestination = all.firstIndex { $0.id == section.shares[destination].id } ?? all.count
        } else if let last = section.shares.last, let i = all.firstIndex(where: { $0.id == last.id }) {
            globalDestination = i + 1
        } else {
            globalDestination = all.count
        }
        model.store.moveShares(from: globalSource, to: globalDestination)
    }

    private var navigationTitle: String {
        switch filter {
        case .all: String(localized: "All Shares")
        case .attention: String(localized: "Needs Attention")
        case .group(let id): model.config.group(id: id)?.name ?? String(localized: "Group")
        }
    }

    private var subtitle: String {
        let shares = filtered
        guard !shares.isEmpty else { return "" }
        let mounted = shares.filter { model.runtime($0.id).state.isMounted }.count
        return mounted == 0 ? String(localized: "None mounted") : String(localized: "\(mounted) of \(shares.count) mounted")
    }

    private var emptyTitle: String {
        switch filter {
        case .attention: String(localized: "All Good")
        case .group: String(localized: "No Shares in This Group")
        case .all: String(localized: "No Shares")
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .attention: "checkmark.circle"
        default: "folder"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .attention: String(localized: "Every share is working normally.")
        case .group: String(localized: "Drag shares here from All Shares.")
        case .all: ""
        }
    }
}

struct ShareRow: View {
    @Environment(AppModel.self) private var model
    var share: Share
    var isSelected = false
    @State private var isHovering = false

    var body: some View {
        let rt = model.runtime(share.id)
        HStack(spacing: 10) {
            ShareIconView(icon: share.icon, size: 32, isDimmed: !rt.state.isMounted)
            VStack(alignment: .leading, spacing: 1) {
                Text(share.name)
                    .lineLimit(1)
                StatusLine(share: share, runtime: rt)
            }
            Spacer(minLength: 8)
            accessory(rt)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }

    /// Eject for mounted shares (like the Finder sidebar), a spinner while working, and a Mount
    /// button that appears on hover so idle rows stay quiet.
    @ViewBuilder
    private func accessory(_ rt: ShareRuntime) -> some View {
        if rt.state.isMounted && !rt.isBusy {
            Button {
                Task { await model.coordinator.unmount(share.id) }
            } label: {
                Image(systemName: "eject.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Unmount")
            .accessibilityLabel("Unmount")
        } else if rt.isTrying && isHovering {
            Button {
                Task { await model.coordinator.unmount(share.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Stop Trying")
            .accessibilityLabel("Stop Trying")
        } else if rt.isBusy || rt.isTrying {
            ProgressView().controlSize(.small)
        } else if isHovering || isSelected {
            Button("Mount") { model.coordinator.mount(share.id) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }
}

/// The secondary line of a share: where it is, or what's wrong.
struct StatusLine: View {
    var share: Share
    var runtime: ShareRuntime
    /// Show the location or error message. Off where those are shown elsewhere (the inspector).
    var showsDetail = true

    var body: some View {
        let state = runtime.state
        HStack(spacing: 5) {
            if state.isMounted || state.isProblem {
                Circle()
                    .fill(state.tone.color)
                    .frame(width: 6, height: 6)
            }
            text
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.subheadline)
        .foregroundStyle(state.isProblem ? AnyShapeStyle(state.tone.color) : AnyShapeStyle(.secondary))
    }

    private var text: Text {
        let state = runtime.state
        switch state {
        case .mounted:
            if runtime.activeAddressKind == .tailscale { return Text("Mounted via Tailscale") }
            return Text("Mounted")
        case .disconnected:
            if let next = runtime.nextRetryAt, next > .now {
                return Text("Retrying in \(Text(next, style: .relative))")
            }
            return showsDetail ? Text(verbatim: share.locationSummary) : Text("Not Mounted")
        case .paused, .connecting, .reconnecting, .unmounting, .waking, .stale:
            return Text(verbatim: state.title)
        case .authFailed, .hostUnreachable, .tailscaleDown, .failed:
            return Text(verbatim: showsDetail ? (runtime.lastError ?? state.title) : state.title)
        }
    }
}

struct ShareContextMenu: View {
    @Environment(AppModel.self) private var model
    var shareID: UUID
    var actions: ShareActions

    var body: some View {
        if let share = model.config.share(id: shareID) {
            let rt = model.runtime(shareID)
            if let path = rt.mountPoint, rt.state.isMounted {
                Button("Open in Finder", systemImage: "folder") { FinderIntegration.open(path) }
                Button("Open in \(FinderIntegration.preferredTerminal.name)", systemImage: "terminal") { FinderIntegration.openInTerminal(path) }
                Divider()
            }

            if rt.state.isMounted {
                Button("Unmount", systemImage: "eject") { Task { await model.coordinator.unmount(shareID) } }
                if rt.state == .stale {
                    Button("Force Unmount", systemImage: "eject.circle") { Task { await model.coordinator.unmount(shareID, force: true) } }
                }
                Button("Reconnect", systemImage: "arrow.clockwise") { model.coordinator.reconnect(shareID) }
            } else if rt.isTrying {
                Button("Stop Trying", systemImage: "xmark") { Task { await model.coordinator.unmount(shareID) } }
            } else {
                Button("Mount", systemImage: "externaldrive.badge.plus") { model.coordinator.mount(shareID) }
            }

            Divider()
            Button("Edit…", systemImage: "pencil") { actions.edit(shareID) }
            if share.auth == .registered {
                Button("Change Password…", systemImage: "key") { actions.changeCredentials(shareID) }
            }
            if rt.state == .mounted {
                Button("Speed Test…", systemImage: "gauge.with.dots.needle.67percent") { actions.speedTest(shareID) }
            }
            Button("Show Activity", systemImage: "list.bullet.rectangle") { model.showLog(for: shareID) }

            Divider()
            if let path = rt.mountPoint, rt.state.isMounted {
                Button("Copy Path", systemImage: "doc.on.doc") { FinderIntegration.copyPath(path) }
            }
            Button("Copy SMB Address", systemImage: "link") { FinderIntegration.copyURL(share) }

            Divider()
            if !model.config.groups.isEmpty {
                Picker(selection: Binding(get: { share.groupID }, set: { model.move(shareID, toGroup: $0) })) {
                    Text("None").tag(UUID?.none)
                    Divider()
                    ForEach(model.config.groups) { Text($0.name).tag(UUID?.some($0.id)) }
                } label: {
                    Label("Group", systemImage: "folder")
                }
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(share) }
            Button("Delete…", systemImage: "trash", role: .destructive) { actions.delete(shareID) }
        }
    }
}

/// First-run empty state with the two ways to get started.
struct EmptySharesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No Shares", systemImage: "externaldrive.connected.to.line.below")
        } description: {
            Text("Add a share and Berth keeps it mounted — at home, over Tailscale and after sleep.")
        } actions: {
            Button("New Share…") { model.pendingRoute = .newShare(prefill: nil) }
                .buttonStyle(.borderedProminent)
            Button("Import from Finder…") { model.pendingRoute = .importShares }
                .buttonStyle(.link)
        }
    }
}
