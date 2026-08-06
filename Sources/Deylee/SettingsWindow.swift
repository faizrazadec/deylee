import AppKit
import SwiftUI

/// The Settings window: a plain titled window, and only ever one of it.
///
/// Deylee is an accessory app, so it has no Dock icon and no menu bar of its own until
/// a real window opens. Settings raises the activation policy to `.regular` while it
/// is up — a window the user has to type into needs Edit-menu keyboard shortcuts and
/// a way back to it after clicking away — and drops it again once the last ordinary
/// window has gone.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let sync: SyncCoordinator?
    private let model: SettingsModel
    private var window: NSWindow?

    /// Called after the window has been destroyed, so the owner can forget it.
    var onClose: (() -> Void)?

    init(model: SettingsModel, sync: SyncCoordinator? = nil) {
        self.sync = sync
        self.model = model
        super.init()
    }

    var isOpen: Bool { window != nil }

    /// Shows the window, or brings the existing one forward.
    ///
    /// A second window would be a second view of the same store: both would show the
    /// same values, but only the one that was clicked would flash "Saved", so the other
    /// would silently disagree about whether anything had happened.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.settingsSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, sync: sync))
        // Set after the hosting controller, which would otherwise size the window to
        // whatever its content happens to fit.
        window.setContentSize(Layout.settingsSize)
        window.contentMinSize = Layout.settingsMinSize
        // The controller drops its reference in `windowWillClose`, so AppKit must not
        // also free the window while the notification is still being delivered.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("deylee.settings")

        self.window = window
        model.hostWindow = window

        DockPresence.acquire()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.hostWindow = nil
        onClose?()
        DockPresence.releaseIfLastWindow()
    }

}
