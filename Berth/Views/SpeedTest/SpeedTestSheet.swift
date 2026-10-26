import SwiftUI
import BerthKit

struct SpeedTestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let shareID: UUID

    @State private var size = 256
    @State private var phase: SpeedTest.Phase?
    @State private var result: SpeedTest.Result?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        let share = model.config.share(id: shareID)
        let rt = model.runtime(shareID)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "speedometer")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed Test").font(.title3.weight(.semibold))
                    Text(share?.name ?? "").foregroundStyle(.secondary)
                }
            }

            if let result {
                HStack(spacing: 0) {
                    SpeedFigure(title: "Read", value: String(format: "%.0f", result.readMBps), unit: "MB/s")
                    Divider().frame(height: 44)
                    SpeedFigure(title: "Write", value: String(format: "%.0f", result.writeMBps), unit: "MB/s")
                    Divider().frame(height: 44)
                    SpeedFigure(title: "Metadata", value: String(format: "%.0f", result.metadataOpsPerSecond), unit: "ops/s")
                }
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(verdict(result)).font(.callout).foregroundStyle(.secondary)
            } else if let phase {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: phase.fraction)
                    Text("\(phase.title)…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Writes a temporary file to the share, reads it back with caching disabled, then creates and deletes small files to measure metadata performance. Everything is cleaned up afterwards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Test file size", selection: $size) {
                    Text("64 MB").tag(64)
                    Text("256 MB").tag(256)
                    Text("1 GB").tag(1024)
                }
                .pickerStyle(.segmented)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if rt.state != .mounted && phase == nil && result == nil {
                Label("Mount the share first.", systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }

            HStack {
                if let path = rt.mountPoint, result != nil {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if phase != nil && result == nil {
                    Button("Stop") { task?.cancel() }
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(result == nil ? "Start" : "Run Again") { start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(rt.state != .mounted)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard let path = model.runtime(shareID).mountPoint else { return }
        result = nil
        error = nil
        phase = .writing(0)
        let config = SpeedTest.Configuration(fileSizeMB: size)
        task = Task {
            do {
                let r = try await SpeedTest.run(mountPoint: path, configuration: config) { p in
                    Task { @MainActor in phase = p }
                }
                result = r
                model.speedTestResults[shareID] = r
                if let share = model.config.share(id: shareID) {
                    model.log.add(.info, String(format: "Speed test: read %.0f MB/s, write %.0f MB/s, %.0f metadata ops/s",
                                                r.readMBps, r.writeMBps, r.metadataOpsPerSecond), share: share)
                }
            } catch {
                self.error = error.localizedDescription
            }
            phase = nil
        }
    }

    private func verdict(_ r: SpeedTest.Result) -> String {
        let throughput = min(r.readMBps, r.writeMBps)
        switch throughput {
        case 900...: return String(localized: "That’s faster than 10 GbE can be pushed by most NAS disks. Excellent.")
        case 100..<900: return String(localized: "Saturating gigabit or better — this link is in great shape.")
        case 40..<100: return String(localized: "Good for most work. Wired Ethernet or the Fast LAN preset may help.")
        case 8..<40: return String(localized: "Typical for Wi-Fi or a remote connection. Try the Tailscale/WAN preset if this is over the internet.")
        default: return String(localized: "Slow. Check for signing being required, Wi-Fi interference, or a congested tunnel.")
        }
    }
}
