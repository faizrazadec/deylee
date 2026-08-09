import AppKit
import SwiftUI
import DeyleeKit

/// The History window: one instance, destroyed when it closes.
///
/// It owns the two subscriptions the window needs to stay honest — a fresh snapshot
/// after any timer transition, and preference changes that move the week start or the
/// default target — and drops both on close so a closed window is not still reading the
/// database on every tick of the timer.
@MainActor
final class HistoryWindow: NSObject, NSWindowDelegate {
    /// The live instance. A second History window would be a second answer to the same
    /// question, and the first one to be edited would silently go stale.
    private static var current: HistoryWindow?

    private let window: NSWindow
    private let model: HistoryModel
    private let engine: TimerEngine
    private var snapshotToken: UUID?
    private var stopWatchingPreferences: PreferencesUnsubscribe?

    /// Opens the window, or brings the existing one forward.
    static func open(repo: Repository, engine: TimerEngine, prefs: PreferencesStore) {
        if let current {
            // Re-read on the way forward. The window survives being sent behind
            // something else, and a sync running in the meantime can have pulled
            // another device's rows or marked one of this device's as refused — neither
            // of which goes through the engine snapshot the model otherwise listens to.
            current.model.reload()
            current.focus()
            return
        }
        let window = HistoryWindow(repo: repo, engine: engine, prefs: prefs)
        current = window
        DockPresence.acquire()
        window.focus()
    }

    private init(repo: Repository, engine: TimerEngine, prefs: PreferencesStore) {
        self.engine = engine
        let service = HistoryService(repo: repo, prefs: prefs)
        let model = HistoryModel(repo: repo, service: service, prefs: prefs)
        self.model = model

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.historySize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "History"
        window.contentMinSize = Layout.historyMinSize
        window.contentViewController = NSHostingController(rootView: HistoryView(model: model))
        // Setting a content view controller makes AppKit adopt *its* fitting size, which
        // would open the window at whatever width SwiftUI considers ideal — narrow enough
        // to squeeze the list's day column to nothing. The design size wins.
        window.setContentSize(Layout.historySize)
        // The controller, not AppKit, decides when this window dies; it is still holding
        // subscriptions that have to come down first.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        model.hostWindow = window
        // A manual edit rewrites the same rows the timer writes, so the rest of the app
        // is told through the same channel a transition uses: one fresh snapshot, which
        // the panel and the status item are already listening for.
        model.onMutated = { [weak self] _ in
            _ = try? self?.engine.emit()
        }

        // Any transition — start, pause, end day, a midnight rollover — rewrites today's
        // segments, so the snapshot doubles as the "history changed" signal.
        snapshotToken = engine.onSnapshot { [weak model] _ in
            model?.reload()
        }

        stopWatchingPreferences = prefs.onChange { [weak model] next in
            // Preference listeners are called from whichever thread wrote the value.
            Task { @MainActor in model?.applyPreferences(next) }
        }
    }

    private func focus() {
        // An accessory app has no Dock icon to click, so bringing the window forward has
        // to activate the app as well or it opens behind whatever the user was in.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let snapshotToken { engine.removeListener(snapshotToken) }
        snapshotToken = nil
        stopWatchingPreferences?()
        stopWatchingPreferences = nil
        model.hostWindow = nil
        Self.current = nil
        DockPresence.releaseIfLastWindow()
    }
}
