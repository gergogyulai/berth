import SwiftUI
import BerthKit

extension ShareIcon.IconColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .brown: .brown
        case .graphite: .gray
        }
    }
}

/// A share's icon: a tinted squircle with an SF Symbol.
struct ShareIconView: View {
    enum Style { case standard, volume }

    var icon: ShareIcon
    var size: CGFloat
    var style: Style = .standard
    /// Dims the icon (e.g. when unmounted).
    var isDimmed = false

    var body: some View {
        let base = icon.color.color
        let shape = RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
        ZStack {
            shape.fill(
                LinearGradient(colors: [base.mix(with: .white, by: 0.18), base.mix(with: .black, by: 0.12)],
                               startPoint: .top, endPoint: .bottom)
            )
            shape.strokeBorder(.white.opacity(0.22), lineWidth: max(0.5, size / 64))
                .blendMode(.plusLighter)
            Image(systemName: icon.symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: size / 48, y: size / 64)
        }
        .frame(width: size, height: size)
        .padding(style == .volume ? size * 0.08 : 0)
        .shadow(color: style == .volume ? .black.opacity(0.25) : .clear, radius: size * 0.04, y: size * 0.02)
        .saturation(isDimmed ? 0.35 : 1)
        .opacity(isDimmed ? 0.75 : 1)
        .accessibilityHidden(true)
    }
}

extension ShareState.Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .positive: .green
        case .busy: .blue
        case .warning: .orange
        case .negative: .red
        }
    }
}

/// A tiny latency chart.
struct Sparkline: View {
    var values: [Double]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let maxV = values.max(), let minV = values.min() {
                let range = max(maxV - minV, 1)
                let step = geo.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat((v - minV) / range)) * 0.9 + geo.size.height * 0.05)
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.2), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.addLines(points)
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .accessibilityLabel("Latency history")
    }
}

/// Click, then press a key combination.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? String(localized: "Type shortcut…") : (hotKey?.display ?? String(localized: "Record Shortcut")))
                    .frame(minWidth: 110)
                    .monospaced(hotKey != nil && !isRecording)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            if hotKey != nil {
                Button {
                    hotKey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Escape cancels
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require at least one of ⌘ ⌥ ⌃ so the shortcut doesn't swallow normal typing.
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            hotKey = HotKey(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: HotKeyManager.carbonModifiers(from: flags),
                display: HotKeyManager.displayString(keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers)
            )
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// "12 ms", "1.2 s"
func formatLatency(_ ms: Double) -> String {
    ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.1f s", ms / 1000)
}
