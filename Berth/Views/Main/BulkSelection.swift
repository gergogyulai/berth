import SwiftUI
import BerthKit

/// Several selected shares, and what can be done to each of them right now. Every operation only
/// touches the shares it applies to, so a mixed selection does the sensible thing.
@MainActor
struct ShareBatch {
    let model: AppModel
    /// In list order.
    let shares: [Share]

    init(model: AppModel, ids: Set<UUID>) {
        self.model = model
        shares = model.config.shares.filter { ids.contains($0.id) }
    }

    private func ids(where predicate: (ShareRuntime) -> Bool) -> [UUID] {
        shares.map(\.id).filter { predicate(model.runtime($0)) }
    }

    var mountable: [UUID] { ids { !$0.state.isMounted && !$0.isTrying && !$0.isBusy } }
    var unmountable: [UUID] { ids { $0.state.isMounted || $0.isTrying } }
    var mounted: [UUID] { ids { $0.state.isMounted } }
    var stale: [UUID] { ids { $0.state == .stale } }

    var mountPoints: [String] {
        shares.compactMap { share in
            let rt = model.runtime(share.id)
            return rt.state.isMounted ? rt.mountPoint : nil
        }
    }

    func mount() { mountable.forEach(model.coordinator.mount) }
    func reconnect() { mounted.forEach(model.coordinator.reconnect) }

    func unmount() {
        for id in unmountable { Task { await model.coordinator.unmount(id) } }
    }

    /// Stale shares only: forcing a healthy mount can lose writes in progress.
    func forceUnmount() {
        for id in stale { Task { await model.coordinator.unmount(id, force: true) } }
    }

    func openInFinder() { mountPoints.forEach(FinderIntegration.open) }

    func move(toGroup groupID: UUID?) {
        for share in shares { model.move(share.id, toGroup: groupID) }
    }

    /// "1 Share", "3 Shares".
    static func countTitle(_ count: Int) -> String {
        count == 1 ? String(localized: "1 Share") : String(localized: "\(count) Shares")
    }
}

/// The context menu for more than one selected share.
struct BulkShareMenu: View {
    @Environment(AppModel.self) private var model
    var shareIDs: Set<UUID>
    var actions: ShareActions

    var body: some View {
        let batch = ShareBatch(model: model, ids: shareIDs)
        if !batch.mountPoints.isEmpty {
            Button("Open \(ShareBatch.countTitle(batch.mountPoints.count)) in Finder", systemImage: "folder") { batch.openInFinder() }
            Divider()
        }
        if !batch.mountable.isEmpty {
            Button("Mount \(ShareBatch.countTitle(batch.mountable.count))", systemImage: "externaldrive.badge.plus") { batch.mount() }
        }
        if !batch.unmountable.isEmpty {
            Button("Unmount \(ShareBatch.countTitle(batch.unmountable.count))", systemImage: "eject") { batch.unmount() }
        }
        if !batch.stale.isEmpty {
            Button("Force Unmount \(ShareBatch.countTitle(batch.stale.count))", systemImage: "eject.circle") { batch.forceUnmount() }
        }
        if !batch.mounted.isEmpty {
            Button("Reconnect \(ShareBatch.countTitle(batch.mounted.count))", systemImage: "arrow.clockwise") { batch.reconnect() }
        }

        Divider()
        if !batch.mountPoints.isEmpty {
            Button("Copy Paths", systemImage: "doc.on.doc") { FinderIntegration.copyPath(batch.mountPoints.joined(separator: "\n")) }
        }
        Button("Copy SMB Addresses", systemImage: "link") { FinderIntegration.copyURLs(batch.shares) }

        Divider()
        if !model.config.groups.isEmpty {
            Menu("Move to Group", systemImage: "folder") {
                Button("None") { batch.move(toGroup: nil) }
                Divider()
                ForEach(model.config.groups) { group in
                    Button(group.name) { batch.move(toGroup: group.id) }
                }
            }
        }
        Button("Delete \(ShareBatch.countTitle(batch.shares.count))…", systemImage: "trash", role: .destructive) { actions.delete(shareIDs) }
    }
}

/// What the inspector shows while several shares are selected.
struct BulkInspector: View {
    @Environment(AppModel.self) private var model
    var shareIDs: Set<UUID>
    var actions: ShareActions

    var body: some View {
        let batch = ShareBatch(model: model, ids: shareIDs)
        VStack(spacing: 0) {
            header(batch)
            Form {
                Section {
                    ForEach(batch.shares) { share in
                        HStack(spacing: 8) {
                            ShareIconView(icon: share.icon, size: 24, isDimmed: !model.runtime(share.id).state.isMounted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(share.name).lineLimit(1)
                                StatusLine(share: share, runtime: model.runtime(share.id))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func header(_ batch: ShareBatch) -> some View {
        VStack(spacing: 10) {
            iconStack(batch.shares)
            VStack(spacing: 3) {
                Text("\(batch.shares.count) Shares Selected")
                    .font(.title3.weight(.semibold))
                Text(batch.mounted.isEmpty ? String(localized: "None Mounted") : String(localized: "\(batch.mounted.count) Mounted"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            InspectorButtonRow {
                Button { batch.mount() } label: { Text("Mount").frame(maxWidth: .infinity) }
                    .disabled(batch.mountable.isEmpty)
                Button { batch.unmount() } label: { Text("Unmount").frame(maxWidth: .infinity) }
                    .disabled(batch.unmountable.isEmpty)
                InspectorMoreMenu { BulkShareMenu(shareIDs: shareIDs, actions: actions) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// Up to three icons fanned out, in the 64pt space a single share's icon takes.
    private func iconStack(_ shares: [Share]) -> some View {
        let shown = Array(shares.prefix(3).enumerated())
        return ZStack {
            ForEach(shown, id: \.element.id) { index, share in
                let offset = CGFloat(index) - CGFloat(shown.count - 1) / 2
                ShareIconView(icon: share.icon, size: 52, isDimmed: !model.runtime(share.id).state.isMounted)
                    .rotationEffect(.degrees(offset * 8))
                    .offset(x: offset * 18)
                    .zIndex(Double(-index))
            }
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }
}

/// The inspector's action buttons, all the same size.
struct InspectorButtonRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .controlSize(.large)
            .buttonSizing(.flexible)
    }
}

/// The "…" button. A text label because an image-only menu comes out shorter than its neighbours.
struct InspectorMoreMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Text(Image(systemName: "ellipsis")).frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .help("More")
        .accessibilityLabel("More")
    }
}
