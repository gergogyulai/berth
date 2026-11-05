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
        InspectorButtonRow {
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
            InspectorMoreMenu { ShareContextMenu(shareID: shareID, actions: actions) }
        }
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
            addressesRow(share, rt)
            row("Share", share.shareName)
            row("User", accountText(share))
        }
    }

    /// Every address, with the one in use marked by an icon for how it's being reached.
    private func addressesRow(_ share: Share, _ rt: ShareRuntime) -> some View {
        let active = rt.state.isMounted ? rt.activeAddress : nil
        return LabeledContent(share.addresses.count == 1 ? "Address" : "Addresses") {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(share.addresses) { address in
                    let isActive = address.display == active
                    let kind = address.resolvedKind
                    HStack(spacing: 4) {
                        if isActive {
                            Image(systemName: kind.symbol)
                                .accessibilityLabel("Connected via \(kind.title)")
                        }
                        Text(address.display)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    // Concrete colors: with the 26.5 SDK, `.secondary` here renders as bright as `.primary`.
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .help(isActive ? "Connected via \(kind.title)" : "")
                }
            }
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

extension AddressKind.Resolved {
    var symbol: String {
        switch self {
        case .lan: "network"
        case .tailscale: "point.3.filled.connected.trianglepath.dotted"
        }
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
