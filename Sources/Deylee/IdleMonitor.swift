import CoreGraphics
import Foundation
import DeyleeKit

/// Watches for the user stepping away from the keyboard while the timer runs.
///
/// Edge-triggered: one report per idle stretch. Without the latch a 10-minute
/// threshold would fire every poll for as long as the user stayed away, burying them
/// in prompts for a single absence. The latch is re-armed only when idle drops back
/// below the threshold — that is the user returning.
@MainActor
final class IdleMonitor {
    /// How often the system idle time is sampled. Cheap enough to poll, and the
    /// resolution the threshold needs.
    static let pollIntervalMs = 15_000

    private var timer: Timer?
    /// True once the current idle stretch has been reported.
    private var reported = false
    private let isRunning: () -> Bool
    private let settings: () -> (enabled: Bool, thresholdMinutes: Int)
    private let onIdleDetected: (_ idleStartedAt: EpochMs, _ idleMs: Int64) -> Void

    init(
        isRunning: @escaping () -> Bool,
        settings: @escaping () -> (enabled: Bool, thresholdMinutes: Int),
        onIdleDetected: @escaping (_ idleStartedAt: EpochMs, _ idleMs: Int64) -> Void
    ) {
        self.isRunning = isRunning
        self.settings = settings
        self.onIdleDetected = onIdleDetected
    }

    func start() {
        stop()
        let interval = Double(Self.pollIntervalMs) / 1_000
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reported = false
    }

    /// Leaving RUNNING ends the stretch as far as the prompt is concerned: whatever
    /// happens next starts a fresh segment.
    func clearLatch() {
        reported = false
    }

    private func tick() {
        let (enabled, thresholdMinutes) = settings()
        guard enabled, isRunning() else {
            reported = false
            return
        }

        let idleMs = Self.systemIdleMs()
        let thresholdMs = Int64(thresholdMinutes) * MS_PER_MINUTE

        if idleMs < thresholdMs {
            reported = false
            return
        }
        if reported { return }
        reported = true
        // The start is derived by subtraction rather than remembered: it stays correct
        // even if a poll was skipped or delayed by timer coalescing.
        onIdleDetected(epochNow() - idleMs, idleMs)
    }

    /// Seconds since the last input event of any kind, in milliseconds.
    static func systemIdleMs() -> Int64 {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .init(rawValue: ~0)!
        )
        return Int64(seconds * 1_000)
    }
}
