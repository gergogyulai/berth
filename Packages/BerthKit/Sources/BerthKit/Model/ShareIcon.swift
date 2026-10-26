import Foundation

/// The icon shown for a share in Berth, and optionally written to the volume.
public struct ShareIcon: Codable, Hashable, Sendable {
    /// SF Symbol name.
    public var symbol: String
    public var color: IconColor

    public init(symbol: String, color: IconColor) {
        self.symbol = symbol
        self.color = color
    }

    public static let `default` = ShareIcon(symbol: "externaldrive.connected.to.line.below.fill", color: .blue)

    public enum IconColor: String, Codable, CaseIterable, Sendable {
        case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown, graphite
    }

    /// A curated set of presets for the icon picker.
    public static let presets: [(title: String, icon: ShareIcon)] = [
        ("NAS", ShareIcon(symbol: "externaldrive.connected.to.line.below.fill", color: .blue)),
        ("Server", ShareIcon(symbol: "server.rack", color: .graphite)),
        ("Media", ShareIcon(symbol: "film.stack.fill", color: .purple)),
        ("Music", ShareIcon(symbol: "music.note", color: .pink)),
        ("Photos", ShareIcon(symbol: "photo.stack.fill", color: .orange)),
        ("Backups", ShareIcon(symbol: "clock.arrow.circlepath", color: .green)),
        ("Time Machine", ShareIcon(symbol: "clock.badge.checkmark.fill", color: .teal)),
        ("Documents", ShareIcon(symbol: "doc.on.doc.fill", color: .indigo)),
        ("Projects", ShareIcon(symbol: "hammer.fill", color: .brown)),
        ("Downloads", ShareIcon(symbol: "arrow.down.circle.fill", color: .cyan)),
        ("Home", ShareIcon(symbol: "house.fill", color: .mint)),
        ("Archive", ShareIcon(symbol: "archivebox.fill", color: .yellow)),
        ("Work", ShareIcon(symbol: "briefcase.fill", color: .red)),
        ("Games", ShareIcon(symbol: "gamecontroller.fill", color: .purple)),
        ("Code", ShareIcon(symbol: "chevron.left.forwardslash.chevron.right", color: .indigo)),
        ("Cloud", ShareIcon(symbol: "cloud.fill", color: .cyan)),
    ]

    /// A broader catalogue of symbols for the picker grid.
    public static let symbolCatalog: [String] = [
        "externaldrive.connected.to.line.below.fill", "externaldrive.fill", "internaldrive.fill",
        "server.rack", "xserve", "macmini.fill", "desktopcomputer", "pc", "laptopcomputer",
        "network", "globe", "cloud.fill", "icloud.fill", "wifi", "antenna.radiowaves.left.and.right",
        "folder.fill", "folder.badge.person.crop", "shared.with.you", "person.2.fill", "person.crop.circle.fill",
        "film.stack.fill", "film.fill", "tv.fill", "play.rectangle.fill", "music.note", "music.note.list",
        "headphones", "photo.stack.fill", "camera.fill", "photo.fill",
        "clock.arrow.circlepath", "clock.badge.checkmark.fill", "archivebox.fill", "shippingbox.fill",
        "tray.full.fill", "doc.on.doc.fill", "doc.text.fill", "books.vertical.fill", "book.closed.fill",
        "graduationcap.fill", "briefcase.fill", "building.2.fill", "house.fill", "sailboat.fill", "ferry.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "chevron.left.forwardslash.chevron.right", "terminal.fill",
        "cpu.fill", "memorychip.fill", "gamecontroller.fill", "paintpalette.fill", "pencil.and.ruler.fill",
        "arrow.down.circle.fill", "square.and.arrow.down.fill", "lock.fill", "key.fill", "shield.lefthalf.filled",
        "star.fill", "heart.fill", "bolt.fill", "leaf.fill", "flame.fill", "snowflake",
    ]
}
