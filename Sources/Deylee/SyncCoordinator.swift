import AppKit
import DeyleeKit
import Foundation

/// Owns sign-in and sync for the app's lifetime, and decides when to run.
///
/// Kept apart from `SyncService` so that "what a sync does" and "when a sync
/// happens" stay separable. The service can be driven by a test with no timers; the
/// schedule can be changed without touching the protocol.
///
/// Nothing here is on the path of a user action. If the whole coordinator failed to
/// start, the app would keep tracking time exactly as before.
@MainActor
final class SyncCoordinator {
    let auth: AuthService
    let sync: SyncService

    /// Raises the sign-in window. Set by the app, because the window's lifetime and
    /// its effect on the activation policy belong there rather than here.
    var presentSignIn: (() -> Void)?

    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []

    /// Quiet enough not to matter on a laptop battery, frequent enough that another
    /// device's edits show up while you are still looking at the window.
    private static let interval: TimeInterval = 120

    init?(repo: Repository) {
        // A build with no API configured is a valid build — the app is local-first
        // and sync is optional — so this returns nil rather than trapping.
        guard let config = ClientConfig.fromBundle() else { return nil }
        auth = AuthService(config: config, repo: repo)
        sync = SyncService(config: config, repo: repo, auth: auth)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync.syncNow() }
        }

        // Waking is the moment a device is most likely to be behind: the laptop was
        // shut while the phone kept tracking. Syncing on wake rather than waiting out
        // the interval is the difference between "instantly right" and "right in two
        // minutes".
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.sync.syncNow() }
        }
        // Likewise on activation: the user has come back to the app and is about to
        // look at numbers that may be stale.
        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.sync.syncNow() }
        }
        observers = [wake, active]

        Task { await sync.syncNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    // No deinit. A `Timer` is not Sendable, so a nonisolated deinit cannot touch it
    // under Swift 6 — and this object lives for the process's lifetime anyway, so
    // `stop()` is the only teardown that ever actually runs.
}
