import AppKit
import Foundation
import DaylyKit

/// Sleep / lock gap tracking.
///
/// The machine going away is reported as an *away* instant, and its return as a
/// closed gap. macOS does not fire these events cleanly in pairs: locking the screen
/// and then suspending emits a lock notification **and** a sleep notification, and
/// waking emits wake **and** unlock. Treating each event as its own gap would count
/// the same absence twice and leave a stale away instant behind forever.
///
/// So one gap is open at a time: the first away event opens it (keeping the earliest
/// instant, which is the one the user actually stopped working at), later away events
/// fold into it, and the first return event closes it. A return with nothing recorded
/// — an unlock after a lock the user chose not to auto-pause on — is ignored.
///
/// None of those notifications is guaranteed to arrive. A wall-clock watchdog covers
/// that: a timer due ten seconds ago that fires an hour late is a sleep nobody
/// announced. It needs no permission, and it is deduplicated against the real events
/// so a machine that does report them never counts one absence twice.
@MainActor
final class PowerMonitor {
    /// How often the wall-clock watchdog looks for a jump. Frequent enough that the
    /// gap it reports starts within a tick of the real sleep, cheap enough to ignore:
    /// one `Date()` comparison.
    static let watchdogIntervalMs: Int64 = 10_000

    /// How far the clock must jump past the interval before it counts as an absence.
    /// A loaded machine can delay a timer by a second or two, and a tick that merely
    /// ran late is not a sleep. Well under the shortest nap anyone takes, comfortably
    /// above ordinary scheduler jitter.
    static let driftThresholdMs: Int64 = 60_000

    private struct AwayMark {
        let at: EpochMs
        let reason: WakeReason
    }

    private let autoPauseOnSleep: () -> Bool
    private let autoPauseOnLock: () -> Bool
    private let onAway: (EpochMs, WakeReason) -> Void
    private let onBack: (_ awayAt: EpochMs, _ backAt: EpochMs, WakeReason) -> Void

    private var away: AwayMark?
    private var started = false
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []

    /// When the watchdog last ran, so the next tick can measure how long it really took.
    private var lastTickAt: EpochMs = 0
    /// When a gap last closed, so a wake that already reported an absence is not
    /// reported a second time by the watchdog noticing the same jump.
    ///
    /// Nil rather than 0 for "never": 0 is a real instant, and comparing it against a
    /// tick that also happens to be 0 would read as "already reported" when nothing
    /// has been.
    private var lastGapClosedAt: EpochMs?

    init(
        autoPauseOnSleep: @escaping () -> Bool,
        autoPauseOnLock: @escaping () -> Bool,
        onAway: @escaping (EpochMs, WakeReason) -> Void,
        onBack: @escaping (_ awayAt: EpochMs, _ backAt: EpochMs, WakeReason) -> Void
    ) {
        self.autoPauseOnSleep = autoPauseOnSleep
        self.autoPauseOnLock = autoPauseOnLock
        self.onAway = onAway
        self.onBack = onBack
    }

    func start() {
        if started { return }
        started = true

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.markAway(.suspend)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.markBack()
        }

        // Screen lock and unlock are only published on the distributed centre.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.markAway(.lockScreen)
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.markBack()
        }

        lastTickAt = epochNow()
        let interval = Double(Self.watchdogIntervalMs) / 1_000
        watchdog = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForClockJump() }
        }
    }

    func stop() {
        if !started { return }
        started = false
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        watchdog?.invalidate()
        watchdog = nil
        // Drop the pending gap: nothing will be listening to close it.
        away = nil
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping () -> Void
    ) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated(handler)
        })
    }

    /// Notices a sleep the OS never announced.
    ///
    /// A timer that should have fired ten seconds ago and fired an hour ago is the
    /// evidence. The interval before the jump is the absence: `lastTickAt` is the last
    /// moment the process was demonstrably awake. Without this, a laptop closed at
    /// lunch comes back having "worked" through it, which is the one number Dayly
    /// exists to get right.
    private func checkForClockJump() {
        let now = epochNow()
        let expected = lastTickAt + Self.watchdogIntervalMs
        let previousTickAt = lastTickAt
        lastTickAt = now

        if now - expected < Self.driftThresholdMs { return }
        // Sleep fired and wake has not: the gap is already open and its instant is more
        // accurate than ours. Let the real event close it.
        if away != nil { return }
        // A sleep/wake pair already reported this same absence. Anything that closed
        // during the window we just slept through is that pair, not an earlier one.
        if let lastGapClosedAt, lastGapClosedAt >= previousTickAt { return }
        if !autoPauseOnSleep() { return }

        lastGapClosedAt = now
        onAway(previousTickAt, .suspend)
        onBack(previousTickAt, now, .suspend)
    }

    private func markAway(_ reason: WakeReason) {
        guard autoPauseEnabled(reason) else { return }
        // A gap is already open (lock, then suspend): keep its earlier instant.
        if away != nil { return }

        let at = epochNow()
        away = AwayMark(at: at, reason: reason)
        onAway(at, reason)
    }

    private func markBack() {
        guard let mark = away else { return }
        let backAt = epochNow()
        away = nil
        // Recorded so the watchdog does not report the same absence again when it
        // notices the clock jumped across this very sleep.
        lastGapClosedAt = backAt
        // The reason is the one that opened the gap, not the one that closed it, so the
        // prompt the user sees matches the pause they were told about.
        onBack(mark.at, backAt, mark.reason)
    }

    private func autoPauseEnabled(_ reason: WakeReason) -> Bool {
        reason == .suspend ? autoPauseOnSleep() : autoPauseOnLock()
    }
}
