import AppKit

/// Whether Deylee appears in the Dock and the app switcher.
///
/// The app runs as an accessory: a menu-bar tracker with a Dock icon it never uses would
/// be a second place to look for it. A real window is the exception — a window with no
/// Dock icon cannot be brought back once it goes behind something, and Cmd-Tab would not
/// reach it. So the policy follows the window count: the first Dock-visible window turns
/// the icon on and the last one to close turns it off again.
///
/// Shared rather than reimplemented per window: History and Settings open and close
/// independently, and whichever closed first would otherwise take the Dock icon away
/// from the one still on screen.
@MainActor
enum DockPresence {
    static func acquire() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Back to an accessory app once nothing is left on screen but the status item.
    ///
    /// The live windows are asked rather than a counter kept here: a count would have to
    /// be shared between every window correctly, forever. Deferred by a turn of the run
    /// loop because the closing window is still listed in `NSApp.windows` while
    /// `windowWillClose` is being delivered.
    static func releaseIfLastWindow() {
        Task { @MainActor in
            let hasOrdinaryWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !hasOrdinaryWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
