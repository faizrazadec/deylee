import AppKit
import SwiftUI

/// The popover panel, as a non-activating `NSPanel` rather than an `NSPopover`.
///
/// A plain panel is what the Electron build used (`type: 'panel'`) and it keeps two
/// behaviours a popover would take away: it floats over full-screen apps, and showing
/// it never activates Deylee over whatever the user is actually working in. Closing
/// hides the window instead of destroying it, so reopening is instant.
/// A borderless window refuses key status by default, and a panel that cannot become
/// key never resigns it either — so `windowDidResignKey`, which is the whole
/// blur-to-hide mechanism, would never fire. The `.nonactivatingPanel` style is what
/// makes taking key focus safe here: the panel becomes key without Deylee activating
/// over whatever the user is actually working in.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelWindow: NSObject, NSWindowDelegate {
    private let window: NSPanel
    /// Called whenever the panel appears or disappears, so the status item's
    /// highlight can track it exactly.
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { window.isVisible }

    private var lastHiddenAt: Date?

    init<Content: View>(@ViewBuilder content: () -> Content) {
        window = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.contentViewController = NSHostingController(rootView: content())
        window.isFloatingPanel = true
        window.level = .statusBar
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = Radius.window
            contentView.layer?.masksToBounds = true
        }
    }

    /// Show the panel below `statusItemFrame` (in screen coordinates), horizontally
    /// centred on it and clamped into the screen's work area.
    func show(below statusItemFrame: NSRect?) {
        window.setFrameOrigin(origin(below: statusItemFrame))
        // Key, not merely ordered front: only a window that holds key status can resign
        // it, and resigning it is what dismisses the panel when the user works
        // elsewhere. `.nonactivatingPanel` keeps this from activating the app.
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func hide() {
        guard window.isVisible else { return }
        lastHiddenAt = Date()
        window.orderOut(nil)
        onVisibilityChange?(false)
    }

    func toggle(below statusItemFrame: NSRect?) {
        if window.isVisible {
            hide()
        } else if !hidJustNow {
            show(below: statusItemFrame)
        }
    }

    /// Whether a hide happened in the last instant.
    ///
    /// Clicking the status item while the panel is open can make the panel resign key
    /// — and so hide — before the button's action runs. By the time `toggle` is asked,
    /// the panel is already gone, and a naive toggle would reopen it: the icon would
    /// become impossible to dismiss by clicking, which is the one gesture everyone
    /// tries first. A click arriving this soon after a hide *is* that dismissal.
    ///
    /// The window is short enough that a deliberate reopen never lands inside it.
    private var hidJustNow: Bool {
        guard let lastHiddenAt else { return false }
        return Date().timeIntervalSince(lastHiddenAt) < Self.reopenSuppressionInterval
    }

    private static let reopenSuppressionInterval: TimeInterval = 0.2

    private func origin(below statusItemFrame: NSRect?) -> NSPoint {
        let size = Layout.panelSize
        // A zero rect means the menu bar has not laid the item out yet; centring on
        // the main screen beats anchoring to a placeholder.
        guard let anchor = statusItemFrame, anchor.width > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                  ?? NSScreen.main
        else {
            return centeredOnMainScreen(size: size)
        }

        let work = screen.visibleFrame
        var x = anchor.midX - size.width / 2
        x = min(max(x, work.minX + Space.m), work.maxX - size.width - Space.m)

        var y = anchor.minY - Layout.panelStatusItemGap - size.height
        // Under a top menu bar this can only happen on an unusual layout, but a panel
        // hanging off the bottom of the screen is unusable, so flip it above.
        if y < work.minY {
            y = anchor.maxY + Layout.panelStatusItemGap
        }
        return NSPoint(x: x, y: y)
    }

    private func centeredOnMainScreen(size: CGSize) -> NSPoint {
        guard let work = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(
            x: work.midX - size.width / 2,
            y: work.midY - size.height / 2
        )
    }

    // Blur-to-hide: the panel is dismissed as soon as the user works elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
