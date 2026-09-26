import Foundation

/// An hour slip: a server-signed statement of claimed and witnessed hours for a run of
/// ended days, which the person hands to whoever needs proof.
///
/// The server signs and nothing is stored (SYNC_PROTOCOL.md, *Hour slips*); this is the
/// shape it answers with, plus the rules the app checks before asking, so a refusal is
/// read where the dates are picked rather than one round trip later.
public struct HourSlip: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public let date: String
        public let claimedMs: Int64
        public let witnessedMs: Int64
        /// Old enough that only a UTC-day total of its witness beats survives.
        public let witnessedApproximate: Bool
    }

    /// Where the QR code points: the server's check page for this slip.
    public let url: String
    public let issuedAt: EpochMs
    public let name: String?
    public let email: String
    public let from: String
    public let to: String
    public let timeZone: String
    public let claimedMs: Int64
    public let witnessedMs: Int64
    public let days: [Day]
}

/// The most days one slip covers, matching the server.
public let hourSlipMaxDays = 30

/// Why `from`…`to` cannot go on a slip right now, or nil when it can.
///
/// Only ended days, matching the server: each must be locked (`DayLock.swift`, judged by
/// the trusted clock), or ended by the person with no timer running on it — `isEnded`
/// answers that. An ended day can be reopened; a slip made from it then expires.
public func hourSlipRangeProblem(
    from: DateKey, to: DateKey, now: EpochMs, in zone: TimeZone = .current,
    isEnded: (DateKey) -> Bool = { _ in false }
) -> String? {
    if to < from { return "The last day can't be before the first." }
    if daysBetween(from: from, to: to) + 1 > hourSlipMaxDays {
        return "An hour slip covers at most \(hourSlipMaxDays) days."
    }
    let today = dateKeyOf(now, in: zone)
    for day in eachDay(from: from, to: to)
    where !isDayLocked(day, now: now, in: zone) && !isEnded(day) {
        return day == today ? hourSlipTodayProblem : "An hour slip can only cover days that have ended."
    }
    return nil
}

/// The last seven days that have ended: yesterday back, or the day before that while
/// yesterday is still inside its grace period.
public func defaultHourSlipRange(now: EpochMs, in zone: TimeZone = .current) -> (DateKey, DateKey) {
    let yesterday = addDays(dateKeyOf(now, in: zone), -1)
    let last = isDayLocked(yesterday, now: now, in: zone) ? yesterday : addDays(yesterday, -1)
    return (addDays(last, -6), last)
}

/// The quick choices in the hour slip sheet.
///
/// Today works once the day has been ended; until then choosing it says what to do.
public enum HourSlipPreset: String, CaseIterable, Sendable {
    case today, yesterday, lastSevenDays, custom

    public var label: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastSevenDays: "Last 7 days"
        case .custom: "Custom"
        }
    }

    /// The days the preset stands for, or nil for `.custom`, whose days are picked.
    public func range(now: EpochMs, in zone: TimeZone = .current) -> (DateKey, DateKey)? {
        let today = dateKeyOf(now, in: zone)
        switch self {
        case .today: return (today, today)
        case .yesterday: return (addDays(today, -1), addDays(today, -1))
        case .lastSevenDays: return defaultHourSlipRange(now: now, in: zone)
        case .custom: return nil
        }
    }
}

/// Why today cannot go on a slip yet, in words that say what to do about it.
public let hourSlipTodayProblem = "Today hasn't ended yet. End the day to put it on an hour slip."

/// `faiz@example.com` → `f***@example.com`, for the printed slip. The check page behind
/// the QR code shows the address in full; the paper need not.
public func maskedEmail(_ email: String) -> String {
    guard let at = email.firstIndex(of: "@"), at > email.startIndex else { return "***" }
    return "\(email[email.startIndex])***\(email[at...])"
}
