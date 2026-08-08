import AppKit
import DeyleeKit
import SwiftUI

/// Hosts the sign-in window.
///
/// The spec's section 11 calls for a native title bar and a window "shown once,
/// before the tray item appears". The title bar carries over; the ordering does not.
/// The window is raised by the action that wants an account — pressing Start, or
/// asking from Settings — because the app is whole from the first frame and gating
/// launch demanded a commitment from somebody who had not yet seen what they were
/// committing to.
///
/// Every way out of this window resolves it, and the caller's action then runs
/// regardless: an account is what makes hours follow you between machines, never
/// what permits you to record them.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let auth: AuthService
    private let onResolved: () -> Void
    /// True once the user is through — by signing in, or by choosing to track
    /// without an account because the API was unreachable.
    private(set) var resolved = false

    init(auth: AuthService, onResolved: @escaping () -> Void) {
        self.auth = auth
        self.onResolved = onResolved
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SignInView(
            auth: auth,
            onSignedIn: { [weak self] in self?.finish() },
            onContinueOffline: { [weak self] in self?.finish() }
        )

        let hosting = NSHostingController(rootView: view)
        // The width is fixed by the spec; the height follows the content, because
        // the password field makes the 420 in the design too short.
        let window = NSWindow(contentViewController: hosting)
        window.title = "Deylee"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // A sign-in window nobody can reach is worse than no gate at all, so the
        // app becomes a normal foreground application for as long as this is up.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        guard !resolved else { return }
        resolved = true
        window?.close()
        window = nil
        // Back to an accessory app: the menu bar is where Deylee lives.
        NSApp.setActivationPolicy(.accessory)
        onResolved()
    }

    /// Closing the window without resolving is a decision too — the person does not
    /// want an account right now. Treating it as "quit" would make the close button
    /// a trap, so it falls through to local-only tracking exactly as the offline
    /// path does; Settings still offers to sign in later.
    func windowWillClose(_ notification: Notification) {
        guard !resolved else { return }
        resolved = true
        window = nil
        NSApp.setActivationPolicy(.accessory)
        onResolved()
    }
}
