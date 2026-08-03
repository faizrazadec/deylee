import AppKit
import SwiftUI

/// Owns the NSStatusItem and the transient popover that hosts the panel.
/// Native replacement for the old Electron tray + mac-status-item addon: the
/// status item highlight, click handling and popover anchoring are all AppKit's
/// built-in behavior here.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Dayly")
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.contentViewController = NSHostingController(rootView: PanelView())
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
