import SwiftUI
import BerthKit

struct ShareInspector: View {
    @Environment(AppModel.self) private var model
    var shareID: UUID
    var actions: ShareActions

    var body: some View {
        if let share = model.config.share(id: shareID) {
            let rt = model.runtime(shareID)
            VStack(spacing: 0) {
                header(share, rt)
                Form {
                    if rt.state.isProblem, let error = rt.lastError {
                        problemSection(rt, error)
                    }
                    detailsSection(share, rt)
                    if rt.state.isMounted { mountSection(rt) }
                    if let result = model.speedTestResults[shareID], rt.state.isMounted { speedSection(result) }
                    behaviorSection(share)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .id(shareID)
        }
    }

    // MARK: Header

    private func header(_ share: Share, _ rt: ShareRuntime) -> some View {
        VStack(spacing: 10) {
            ShareIconView(icon: share.icon, size: 64, isDimmed: !rt.state.isMounted)
            VStack(spacing: 3) {
                Text(share.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .textSelection(.enabled)
                StatusLine(share: share, runtime: rt, showsDetail: false)
            }
            actionButtons(rt)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func actionButtons(_ rt: ShareRuntime) -> some View {
        HStack(spacing: 8) {
            if rt.state.isMounted {
                Button { if let p = rt.mountPoint { FinderIntegration.open(p) } } label: { Text("Open").frame(maxWidth: .infinity) }
                Button { Task { await model.coordinator.unmount(shareID) } } label: { Text("Unmount").frame(maxWidth: .infinity) }
            } else if rt.isTrying {
                Button { Task { await model.coordinator.unmount(shareID) } } label: { Text("Stop Trying").frame(maxWidth: .infinity) }
            } else {
                Button { model.coordinator.mount(shareID) } label: { Text("Mount").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(rt.isBusy)
            }
            Menu {
                ShareContextMenu(shareID: shareID, actions: actions)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(height: 16)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .controlSize(.large)
    }

    // MARK: Sections

    private func problemSection(_ rt: ShareRuntime, _ error: String) -> some View {
        Section {
            Label {
                Text(error).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: rt.state.symbol).foregroundStyle(rt.state.tone.color)
            }
            if let next = rt.nextRetryAt, next > .now {
                Text("Trying again in \(Text(next, style: .relative)) · attempt \(rt.attempt + 1)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if rt.state == .authFailed {
                    Button("Update Password…") { actions.changeCredentials(shareID) }
                }
                Spacer()
                Button(rt.nextRetryAt != nil ? "Retry Now" : "Try Again") { model.coordinator.mount(shareID) }
            }
        }
    }

    private func detailsSection(_ share: Share, _ rt: ShareRuntime) -> some View {
        Section {
            let server = rt.state.isMounted ? (rt.activeAddress ?? share.primaryHost) : share.primaryHost
            row("Server", server)
            let fallbacks = share.addresses.map(\.display).filter { $0 != server }
            if !fallbacks.isEmpty {
                row(fallbacks.count == 1 ? "Fallback" : "Fallbacks", fallbacks.joined(separator: "\n"))
            }
            row("Share", share.shareName)
            row("User", accountText(share))
        }
    }

    private func mountSection(_ rt: ShareRuntime) -> some View {
        Section {
            if let path = rt.mountPoint {
                LabeledContent("Location") {
                    Button {
                        FinderIntegration.reveal(path)
                    } label: {
                        Text(path).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Show in Finder")
                }
            }
            if let since = rt.connectedSince {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    row("Connected", since.formatted(.relative(presentation: .named)))
                }
            }
            LabeledContent("Response Time") {
                HStack(spacing: 8) {
                    Sparkline(values: rt.latencyHistory, color: rt.state == .stale ? .orange : .secondary)
                        .frame(width: 48, height: 14)
                    Text(rt.lastProbeLatency.map { formatLatency($0.inMilliseconds) } ?? "—")
                        .monospacedDigit()
                }
            }
        }
    }

    private func speedSection(_ result: SpeedTest.Result) -> some View {
        Section("Speed Test") {
            row("Read", String(format: "%.0f MB/s", result.readMBps))
            row("Write", String(format: "%.0f MB/s", result.writeMBps))
        }
    }

    private func behaviorSection(_ share: Share) -> some View {
        Section {
            row("Mounts", share.autoMount.title)
            if share.networkRule.mode != .anywhere {
                row("Network", share.networkRule.mode.title)
            }
        } footer: {
            HStack {
                Button("Edit Share…") { actions.edit(shareID) }
                Spacer()
                Button("Show Activity") { model.showLog(for: shareID) }
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
    }

    // MARK: Helpers

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value.isEmpty ? "—" : value)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func accountText(_ share: Share) -> String {
        switch share.auth {
        case .guest: String(localized: "Guest")
        case .anonymous: String(localized: "Anonymous")
        case .registered: share.domain.isEmpty ? share.username : "\(share.domain)\\\(share.username)"
        }
    }
}

struct SpeedFigure: View {
    var title: LocalizedStringKey
    var value: String
    var unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

extension EventLog.Entry.Level {
    var color: Color {
        switch self {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
