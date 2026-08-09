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
    let heartbeat: HeartbeatService

    /// Raises the sign-in window. Set by the app, because the window's lifetime and
    /// its effect on the activation policy belong there rather than here.
    var presentSignIn: (() -> Void)?

    /// Whether a work segment is open right now. Set by the app from the model,
    /// because the coordinator deliberately knows nothing about timer state — it
    /// only asks this at each beat, so a paused or ended day goes silent within
    /// half a minute of becoming one.
    var timerIsRunning: () -> Bool = { false }

    private var timer: Timer?
    private var beatTimer: Timer?
    private var observers: [any NSObjectProtocol] = []

    /// Consecutive failures, and the moment the next attempt is allowed.
    ///
    /// Every trigger goes through the same gate — the timer, waking, and activating —
    /// because an outage that fails the timer fails the other two just as reliably, and
    /// activation is the one a person can produce fifty times in a minute.
    private var consecutiveFailures = 0
    private var nextAttemptAt: Date?

    /// Quiet enough not to matter on a laptop battery, frequent enough that another
    /// device's edits show up while you are still looking at the window.
    private static let interval: TimeInterval = 120

    /// Matched to the server's witness maths: each beat vouches for at most 45
    /// seconds back, so thirty-second spacing keeps a running timer continuously
    /// witnessed with headroom for a slow request.
    private static let beatInterval: TimeInterval = 30

    init?(repo: Repository) {
        // A build with no API configured is a valid build — the app is local-first
        // and sync is optional — so this returns nil rather than trapping.
        guard let config = ClientConfig.fromBundle() else { return nil }
        auth = AuthService(config: config, repo: repo)
        sync = SyncService(config: config, repo: repo, auth: auth)
        heartbeat = HeartbeatService(config: config, repo: repo, auth: auth)
    }

    /// Sync, unless a previous failure asked for room.
    ///
    /// Without this the schedule was a flat 120 seconds whatever happened, plus every
    /// wake and every activation — a client hammering a server that is down for as
    /// long as the outage lasts, times every install.
    ///
    /// Only `.failed` counts. `.rejected` means the exchange worked and the server
    /// declined particular rows, which backing off would not help with and which is
    /// already handled by marking those rows.
    private func syncIfDue(now: Date = Date()) async {
        if let nextAttemptAt, now < nextAttemptAt { return }

        await sync.syncNow()

        if case .failed = sync.status {
            consecutiveFailures += 1
            nextAttemptAt = now.addingTimeInterval(
                syncRetryDelay(afterFailures: consecutiveFailures)
            )
        } else {
            consecutiveFailures = 0
            nextAttemptAt = nil
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncIfDue() }
        }
        beatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.beatInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timerIsRunning() else { return }
                await self.heartbeat.beat()
            }
        }

        // Waking is the moment a device is most likely to be behind: the laptop was
        // shut while the phone kept tracking. Syncing on wake rather than waiting out
        // the interval is the difference between "instantly right" and "right in two
        // minutes".
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.syncIfDue() }
        }
        // Likewise on activation: the user has come back to the app and is about to
        // look at numbers that may be stale.
        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.syncIfDue() }
        }
        observers = [wake, active]

        // Through the same gate, though nothing can be owed yet: a launch that fails
        // should start the count, or the first failure would be the one that is free.
        Task { await syncIfDue() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        beatTimer?.invalidate()
        beatTimer = nil
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
