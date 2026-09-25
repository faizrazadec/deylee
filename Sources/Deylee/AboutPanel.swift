import AppKit

/// The About window: AppKit's standard panel, which already reads the icon, name,
/// version, build and copyright from the bundle. Only the credits are ours.
@MainActor
enum AboutPanel {
    static let sourceURL = "https://github.com/faizrazadec/deylee"

    static func show() {
        let credits = NSMutableAttributedString(
            string: "Deylee is open source and can be found on GitHub:\n",
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(
            string: "github.com/faizrazadec/deylee",
            attributes: [.link: URL(string: sourceURL)!]
        ))
        credits.append(NSAttributedString(
            string: "\n\nMade by Muhammad Faiz Raza.\nThanks for using Deylee!",
            attributes: [.foregroundColor: NSColor.labelColor]
        ))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttributes(
            [.paragraphStyle: centred, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)],
            range: NSRange(location: 0, length: credits.length)
        )

        // A menu-bar app is never frontmost on its own; without this the panel opens
        // behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
