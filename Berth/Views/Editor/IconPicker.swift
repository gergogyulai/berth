import SwiftUI
import BerthKit

struct IconPicker: View {
    @Binding var icon: ShareIcon
    @State private var filter = ""

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Presets").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ShareIcon.presets, id: \.title) { preset in
                    Button {
                        icon = preset.icon
                    } label: {
                        ShareIconView(icon: preset.icon, size: 34)
                            .overlay {
                                if preset.icon == icon {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                        .padding(-3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(preset.title)
                    .accessibilityLabel(preset.title)
                }
            }

            Divider()

            Text("Color").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ForEach(ShareIcon.IconColor.allCases, id: \.self) { color in
                    Button {
                        icon.color = color
                    } label: {
                        Circle()
                            .fill(color.color.gradient)
                            .frame(width: 20, height: 20)
                            .overlay {
                                if icon.color == color {
                                    Circle().strokeBorder(.white, lineWidth: 2).padding(3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(color.rawValue.capitalized)
                    .accessibilityLabel(color.rawValue.capitalized)
                }
            }

            HStack {
                Text("Symbol").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .controlSize(.small)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            icon.symbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15))
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(symbol == icon.symbol ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
                                )
                                .foregroundStyle(symbol == icon.symbol ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
            }
            .frame(height: 170)

            HStack {
                TextField("Any SF Symbol name", text: $icon.symbol)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                ShareIconView(icon: icon, size: 28)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var symbols: [String] {
        filter.isEmpty ? ShareIcon.symbolCatalog : ShareIcon.symbolCatalog.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
}
