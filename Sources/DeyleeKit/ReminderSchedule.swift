import Foundation

/// Decides whether the end-of-day nudge is due. Pure, so the rule can be tested at
/// any instant in any zone without waiting a day for a timer to fire.
///
/// The service that owns this compares the wall clock against the due minute on a
/// repeating tick rather than scheduling a timer for the due instant: a long timeout
/// would sleep through a machine suspend and fire late or not at all, and a clock
/// change would leave it aimed at the wrong moment.
public struct ReminderSchedule: Equatable, Sendable {
    /// The day it last fired on, so it fires once rather than every tick for the rest
    /// of the evening. Deliberately not persisted: a relaunch is a new session, and a
    /// nudge missed because the app was closed is not worth replaying hours later.
    public private(set) var lastFiredOn: DateKey?

    public init(lastFiredOn: DateKey? = nil) {
        self.lastFiredOn = lastFiredOn
    }

    /// Whether to fire now, marking the day when it does.
    ///
    /// Mutating on purpose: the day is marked as part of deciding, so a caller whose
    /// notice delivery throws cannot leave the day unmarked and re-fire on every tick.
    public mutating func shouldFire(
        now: EpochMs,
        enabled: Bool,
        isRunning: Bool,
        reminderHour: Int,
        reminderMinute: Int,
        in zone: TimeZone = .current
    ) -> Bool {
        guard enabled, isRunning else { return false }

        let today = dateKeyOf(now, in: zone)
        guard lastFiredOn != today else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: Date(epochMs: now))
        guard let hour = parts.hour, let minute = parts.minute else { return false }

        // Past the due minute, not exactly on it: a tick can land a second late, and a
        // nudge that only fires on an exact match would be skipped for the whole day.
        guard hour * 60 + minute >= reminderHour * 60 + reminderMinute else { return false }

        lastFiredOn = today
        return true
    }
}
