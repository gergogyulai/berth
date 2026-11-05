import SwiftUI
import BerthKit

enum SidebarItem: Hashable {
    case all, attention, group(UUID)
}

/// Draft state for the share editor sheet.
struct ShareDraft: Identifiable {
    var share: Share
    var password: String
    var isNew: Bool
    var id: UUID { share.id }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(DefaultsKey.hasCompletedWelcome) private var hasCompletedWelcome = false
    @SceneStorage("showInspector") private var showInspector = true

    @State private var sidebar: SidebarItem? = .all
    @State private var selectedShares: Set<UUID> = []
    @State private var sheet: SheetRoute?
    @State private var search = ""
    @State private var pendingDeletion: [Share] = []
    /// The group whose name is being edited in the sidebar.
    @State private var editingGroup: UUID?

    enum SheetRoute: Identifiable {
        case editor(ShareDraft)
        case credentials(UUID)
        case importer
        case speedTest(UUID)

        var id: String {
            switch self {
            case .editor(let d): "editor-\(d.id)"
            case .credentials(let id): "credentials-\(id)"
            case .importer: "importer"
            case .speedTest(let id): "speed-\(id)"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar, editingGroup: $editingGroup, selectedShares: selectedShares, newGroup: newGroup)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            ShareListView(filter: sidebar ?? .all, search: search, selection: $selectedShares, actions: actions)
                .searchable(text: $search, placement: .toolbar, prompt: "Search")
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if selectedShares.count > 1 {
                    BulkInspector(shareIDs: selectedShares, actions: actions)
                } else if let id = selectedShares.first, model.config.share(id: id) != nil {
                    ShareInspector(shareID: id, actions: actions)
                } else {
                    ContentUnavailableView("No Share Selected", systemImage: "externaldrive.connected.to.line.below")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
        }
        .toolbar { toolbar }
        .sheet(item: $sheet, content: sheetContent)
        .alert(
            deletionTitle,
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
            presenting: pendingDeletion.isEmpty ? nil : pendingDeletion
        ) { shares in
            Button("Delete", role: .destructive) {
                selectedShares.subtract(shares.map(\.id))
                for share in shares {
                    Task { await model.coordinator.remove(share.id, unmountFirst: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { shares in
            Text(deletionMessage(shares))
        }
        .focusedSceneValue(\.selectedShareIDs, selectedShares)
        .onChange(of: model.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            model.pendingRoute = nil
            handle(route)
        }
        .onAppear {
            OpenWindowBridge.shared.openWindow = openWindow
            OpenWindowBridge.shared.openSettings = openSettings
            if !hasCompletedWelcome && model.config.shares.isEmpty {
                openWindow(id: WindowID.welcome)
                dismissWindow(id: WindowID.main)
            }
        }
        .onChange(of: model.config.shares.map(\.id)) { _, ids in
            selectedShares.formIntersection(ids)
        }
        .onChange(of: model.config.groups.map(\.id)) { _, ids in
            if case .group(let id) = sidebar, !ids.contains(id) { sidebar = .all }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Share…", systemImage: "externaldrive.badge.plus") { newShare() }
                Button("Import Shares…", systemImage: "square.and.arrow.down") { sheet = .importer }
                Divider()
                Button("New Group", systemImage: "folder.badge.plus") { newGroup() }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                newShare()
            }
            .help("New Share")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    @ViewBuilder
    private func sheetContent(_ route: SheetRoute) -> some View {
        switch route {
        case .editor(let draft):
            ShareEditorView(draft: draft) { saved in selectedShares = [saved.id] }
                .environment(model)
        case .credentials(let id):
            CredentialsSheet(shareID: id)
                .environment(model)
        case .importer:
            ImportSheet { draft in
                sheet = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    sheet = .editor(draft)
                }
            }
            .environment(model)
        case .speedTest(let id):
            SpeedTestSheet(shareID: id)
                .environment(model)
        }
    }

    // MARK: Actions

    private var actions: ShareActions {
        ShareActions(
            edit: { id in
                if let share = model.config.share(id: id) {
                    sheet = .editor(ShareDraft(share: share, password: "", isNew: false))
                }
            },
            changeCredentials: { sheet = .credentials($0) },
            speedTest: { sheet = .speedTest($0) },
            delete: { ids in pendingDeletion = model.config.shares.filter { ids.contains($0.id) } }
        )
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1, let share = pendingDeletion.first {
            return String(localized: "Delete “\(share.name)”?")
        }
        return String(localized: "Delete \(pendingDeletion.count) Shares?")
    }

    private func deletionMessage(_ shares: [Share]) -> LocalizedStringKey {
        let anyMounted = shares.contains { model.runtime($0.id).state.isMounted }
        if shares.count == 1 {
            return anyMounted
                ? "The share will be unmounted and its password removed from your Keychain."
                : "Its password will be removed from your Keychain."
        }
        return anyMounted
            ? "Mounted shares will be unmounted, and all of their passwords removed from your Keychain."
            : "Their passwords will be removed from your Keychain."
    }

    private func newShare(prefill: Share? = nil) {
        var share = prefill ?? Share()
        if prefill == nil, case .group(let id) = sidebar { share.groupID = id }
        model.assignFreshColor(to: &share)
        sheet = .editor(ShareDraft(share: share, password: "", isNew: true))
    }

    /// Creates a group and puts its name into edit mode in the sidebar, like a new folder in Finder.
    private func newGroup() {
        let group = model.addGroup(named: String(localized: "New Group"))
        sidebar = .group(group.id)
        editingGroup = group.id
    }

    private func handle(_ route: AppModel.Route) {
        switch route {
        case .newShare(let prefill): newShare(prefill: prefill)
        case .newGroup: newGroup()
        case .editShare(let id): actions.edit(id)
        case .changeCredentials(let id): selectedShares = [id]; sheet = .credentials(id)
        case .importShares: sheet = .importer
        case .speedTest(let id): selectedShares = [id]; sheet = .speedTest(id)
        case .select(let id):
            // Make sure the share is visible under the current sidebar filter.
            switch sidebar {
            case .group(let groupID) where model.config.share(id: id)?.groupID != groupID: sidebar = .all
            case .attention where !model.runtime(id).state.isProblem: sidebar = .all
            default: break
            }
            selectedShares = [id]
            showInspector = true
        }
    }
}

/// Closures the list, inspector and menus use to ask the window for sheets.
struct ShareActions {
    var edit: (UUID) -> Void
    var changeCredentials: (UUID) -> Void
    var speedTest: (UUID) -> Void
    var delete: (Set<UUID>) -> Void
}
