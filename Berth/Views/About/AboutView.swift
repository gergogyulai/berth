import AppKit
import BerthKit

/// The standard About panel, with the acknowledgements as its credits.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6

        func run(_ string: String, _ font: NSFont, _ color: NSColor = .secondaryLabelColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }

        let text = NSMutableAttributedString()
        func link(_ title: String, _ url: URL) {
            let start = text.length
            text.append(run(title, bold, .linkColor))
            text.addAttribute(.link, value: url, range: NSRange(location: start, length: text.length - start))
        }
        text.append(run(String(localized: "Built entirely on Apple frameworks — NetFS, DiskArbitration, Network, CoreWLAN, Security and App Intents.\n"), body))
        link(String(localized: "Website"), Links.website)
        text.append(run("  ·  ", body, .tertiaryLabelColor))
        link(String(localized: "Report an Issue"), Links.issues)
        text.append(run(String(localized: "\n\nTailscale is a trademark of Tailscale Inc. Berth is not affiliated with Tailscale."), body, .tertiaryLabelColor))
        return text
    }
}
