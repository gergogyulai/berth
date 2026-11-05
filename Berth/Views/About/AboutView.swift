import AppKit
import BerthKit

/// The standard About panel: icon, name, version and a link to the project.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: String(localized: "Website"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .link: Links.website,
            .paragraphStyle: paragraph,
        ])
    }
}
