import SwiftUI
import BerthKit

/// Per-server nsmb.conf editor with presets and a raw view.
struct SMBSettings: View {
    @Environment(AppModel.self) private var model
    @State private var conf = NSMBConf()
    @State private var selected: String = "default"
    @State private var showRaw = false
    @State private var rawText = ""
    @State private var status: String?
    @State private var isDirty = false
    @State private var newServer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Server", selection: $selected) {
                    Text("All Servers").tag("default")
                    Divider()
                    ForEach(serverNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(maxWidth: 320)
                Menu {
                    ForEach(knownHosts, id: \.self) { host in
                        Button(host) { addSection(host) }
                    }
                    if !knownHosts.isEmpty { Divider() }
                    Button("Other Server…") { promptServer() }
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
                Toggle("Edit as Text", isOn: $showRaw)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if showRaw {
                TextEditor(text: $rawText)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 320)
                    .padding(20)
                    .onChange(of: rawText) { isDirty = true }
            } else {
                Form {
                    Section {
                        HStack(spacing: 10) {
                            ForEach(PerformancePreset.allCases) { preset in
                                PresetCard(preset: preset, isActive: currentSection.map { PerformancePreset.matching($0) == preset } ?? false) {
                                    conf.withSection(named: selected) { preset.apply(to: &$0) }
                                    isDirty = true
                                }
                            }
                        }
                    } header: {
                        Text("Presets")
                    } footer: {
                        Text("Changes apply the next time a share mounts.").foregroundStyle(.secondary)
                    }
                    Section(selected == "default" ? String(localized: "Options for All Servers") : String(localized: "Options for \(selected)")) {
                        ForEach(NSMBOption.all) { option in
                            OptionRow(option: option, value: binding(for: option.key))
                        }
                    }
                    if selected != "default" {
                        Section {
                            Button("Remove [\(selected)] Section", role: .destructive) {
                                conf.removeSection(named: selected)
                                selected = "default"
                                isDirty = true
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minHeight: 420)
            }

            HStack {
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([NSMBConf.userFileURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: NSMBConf.userFileURL.path))
                Button("Revert") { load() }.disabled(!isDirty)
                Button("Save") { save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear(perform: load)
        .onChange(of: showRaw) { _, raw in
            if raw { rawText = conf.serialized() } else { conf = NSMBConf(parsing: rawText) }
        }
    }

    private var currentSection: NSMBConf.Section? { conf.section(named: selected) }

    private var serverNames: [String] {
        conf.sections.map(\.name).filter { $0.lowercased() != "default" }
    }

    private var knownHosts: [String] {
        let existing = Set(serverNames.map { $0.uppercased() })
        return model.config.shares.flatMap(\.addresses).map { NSMBConf.sectionName(forHost: $0.trimmedHost) }
            .filter { !$0.isEmpty && !existing.contains($0) }
            .uniquedStrings()
    }

    private func binding(for key: String) -> Binding<String?> {
        Binding(
            get: { conf.section(named: selected)?[key] },
            set: { value in
                conf.withSection(named: selected) { $0[key] = value }
                isDirty = true
            }
        )
    }

    private func addSection(_ name: String) {
        conf.withSection(named: name) { _ in }
        selected = name
        isDirty = true
    }

    private func promptServer() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Add Server Section")
        alert.informativeText = String(localized: "Enter the server’s name as you connect to it (e.g. NAS or nas.local).")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { addSection(NSMBConf.sectionName(forHost: name)) }
        }
    }

    private func load() {
        conf = NSMBConfEditor.load()
        rawText = conf.serialized()
        isDirty = false
        status = nil
        if selected != "default" && conf.section(named: selected) == nil { selected = "default" }
    }

    private func save() {
        if showRaw { conf = NSMBConf(parsing: rawText) }
        do {
            try conf.write()
            isDirty = false
            status = String(localized: "Saved. A backup of the original is next to the file (nsmb.conf.berth-backup).")
            model.log.add(.info, "nsmb.conf updated")
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct PresetCard: View {
    let preset: PerformancePreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: preset.symbol)
                        .foregroundStyle(isActive ? Color.white : Color.accentColor)
                    Spacer()
                    if isActive { Image(systemName: "checkmark").foregroundStyle(.white) }
                }
                Text(preset.title).font(.callout.weight(.semibold))
                Text(preset.summary)
                    .font(.caption2)
                    .foregroundStyle(isActive ? .white.opacity(0.85) : .secondary)
                    .lineLimit(4, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isActive ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Apply \(preset.title)")
    }
}

private struct OptionRow: View {
    let option: NSMBOption
    @Binding var value: String?

    var body: some View {
        switch option.kind {
        case .bool:
            Picker(selection: Binding(get: { value?.lowercased() ?? "" }, set: { value = $0.isEmpty ? nil : $0 })) {
                Text("Default").tag("")
                Text("Yes").tag("yes")
                Text("No").tag("no")
            } label: {
                label
            }
        case .choice(let choices):
            Picker(selection: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 })) {
                Text("Default").tag("")
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            } label: {
                label
            }
        case .text(let placeholder):
            TextField(text: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 }), prompt: Text(placeholder)) {
                label
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(option.title)
                Text(option.key).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Text(option.help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Array where Element == String {
    func uniquedStrings() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
