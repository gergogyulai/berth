import SwiftUI
import BerthKit
import UniformTypeIdentifiers

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var minimumLevel: EventLog.Entry.Level = .info
    @State private var shareFilter: UUID?
    @State private var search = ""
    @State private var selection = Set<EventLog.Entry.ID>()
    @State private var followTail = true

    var body: some View {
        let entries = filtered
        Table(entries, selection: $selection) {
            TableColumn("Time") { entry in
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80, max: 100)
            TableColumn("") { entry in
                Image(systemName: entry.level.symbol)
                    .foregroundStyle(entry.level.color)
                    .help(entry.level.rawValue.capitalized)
            }
            .width(18)
            TableColumn("Share") { entry in
                Text(entry.shareName ?? "—").foregroundStyle(entry.shareName == nil ? .tertiary : .primary)
            }
            .width(min: 80, ideal: 120, max: 200)
            TableColumn("Message") { entry in
                Text(entry.message).lineLimit(2).help(entry.message)
            }
        }
        .contextMenu(forSelectionType: EventLog.Entry.ID.self) { ids in
            Button("Copy") { copy(ids) }
        }
        .onCopyCommand { [NSItemProvider(object: text(for: selection) as NSString)] }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle",
                                       description: Text(model.log.entries.isEmpty ? "Mounts, disconnects and errors appear here." : "Nothing matches the current filter."))
            }
        }
        .navigationTitle("Connection Log")
        .onChange(of: model.logShareFilter, initial: true) { _, id in
            guard let id else { return }
            shareFilter = id
            model.logShareFilter = nil
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter Messages")
        .toolbar {
            ToolbarItemGroup {
                Picker("Share", selection: $shareFilter) {
                    Text("All Shares").tag(UUID?.none)
                    Divider()
                    ForEach(model.config.shares) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .fixedSize()
                Picker("Level", selection: $minimumLevel) {
                    Text("Debug").tag(EventLog.Entry.Level.debug)
                    Text("Info").tag(EventLog.Entry.Level.info)
                    Text("Warnings").tag(EventLog.Entry.Level.warning)
                    Text("Errors").tag(EventLog.Entry.Level.error)
                }
                .fixedSize()
                Menu {
                    Button("Copy Diagnostics Report", systemImage: "stethoscope") { Diagnostics.copyReport(model: model) }
                    Button("Export Log…", systemImage: "square.and.arrow.up") { export(entries) }
                    Button("Show Log File in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([EventLog.logFileURL]) }
                    Divider()
                    Button("Clear Log", systemImage: "trash") { model.log.clear() }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
            }
        }
    }

    private var filtered: [EventLog.Entry] {
        model.log.entries.reversed().filter { entry in
            entry.level >= minimumLevel
                && (shareFilter == nil || entry.shareID == shareFilter)
                && (search.isEmpty || entry.message.localizedStandardContains(search) || (entry.shareName?.localizedStandardContains(search) ?? false))
        }
    }

    private func text(for ids: Set<EventLog.Entry.ID>) -> String {
        model.log.text(for: model.log.entries.filter { ids.contains($0.id) })
    }

    private func copy(_ ids: Set<EventLog.Entry.ID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: ids), forType: .string)
    }

    private func export(_ entries: [EventLog.Entry]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Berth Log \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? model.log.text(for: entries.reversed()).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// A plain-text report for bug reports and support.
@MainActor
enum Diagnostics {
    static func report(model: AppModel) -> String {
        let info = ProcessInfo.processInfo
        var lines: [String] = [
            "Berth \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))",
            "macOS \(info.operatingSystemVersionString)",
            "Network: \(model.network.snapshot.summary)",
            "Tailscale: \(model.network.snapshot.tailscale.title)",
            "Generated: \(Date().formatted(.iso8601))",
            "",
            "Shares:",
        ]
        for share in model.config.shares {
            let rt = model.runtime(share.id)
            let addresses = share.addresses.map { "\($0.display) [\($0.resolvedKind.rawValue)]" }.joined(separator: ", ")
            lines.append("- \(share.name): \(rt.state.code)")
            lines.append("    addresses: \(addresses); share: \(share.shareName); auth: \(share.auth.rawValue)")
            lines.append("    rule: \(share.networkRule.mode.rawValue); auto: \(share.autoMount.rawValue); soft: \(share.options.softMount)")
            if let path = rt.mountPoint { lines.append("    mounted at: \(path) via \(rt.activeAddress ?? "?")") }
            if let l = rt.lastProbeLatency { lines.append("    latency: \(formatLatency(l.inMilliseconds))") }
            if let error = rt.lastError { lines.append("    last error: \(error)") }
        }
        lines.append("")
        lines.append("Recent log:")
        lines.append(model.log.text(for: Array(model.log.entries.suffix(150))))
        return lines.joined(separator: "\n")
    }

    static func copyReport(model: AppModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(model: model), forType: .string)
    }
}

/// Export / import of the configuration as JSON.
@MainActor
enum ConfigTransfer {
    static func export(model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Berth Shares.json"
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Passwords are not included.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.exportData().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func importConfiguration(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let alert = NSAlert()
            alert.messageText = String(localized: "Import shares from “\(url.lastPathComponent)”?")
            alert.informativeText = String(localized: "Merging adds new shares and updates ones that already exist. Replacing discards your current configuration.")
            alert.addButton(withTitle: String(localized: "Merge"))
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let response = alert.runModal()
            guard response != .alertThirdButtonReturn else { return }
            let count = try model.store.importData(data, mode: response == .alertFirstButtonReturn ? .merge : .replace)
            model.coordinator.syncRuntimes()
            model.log.add(.info, "Imported configuration (\(count) shares)")
            let done = NSAlert()
            done.messageText = String(localized: "Imported \(count) shares")
            done.informativeText = String(localized: "Passwords aren’t part of the export. Shares that need one will ask when they first mount.")
            done.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
