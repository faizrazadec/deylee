import Foundation

/// Local-calendar time helpers, ported one-to-one from `src/shared/time.ts`.
///
/// Rules that hold everywhere in Dayly:
///  - Instants are UTC epoch milliseconds (`EpochMs`). Nothing else is ever persisted.
///  - A "day" is a *local* calendar day, so it may be 23h or 25h long across DST.
///    Boundary maths therefore resolves wall-clock components through `Calendar`
///    rather than adding fixed millisecond offsets. Like the JS `Date` constructor,
///    `Calendar` resolves nonexistent spring-forward times forward and ambiguous
///    fall-back times to their first occurrence — the ported tests pin both.
///  - Pure calendar arithmetic (adding days, week/month bounds) is zone-independent
///    and runs on a fixed GMT calendar so DST can never touch it.

public typealias EpochMs = Int64

public let MS_PER_SECOND: Int64 = 1_000
public let MS_PER_MINUTE: Int64 = 60_000
public let MS_PER_HOUR: Int64 = 3_600_000

let gmtCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}()

private func calendar(in zone: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = zone
    return c
}

private func pad2(_ value: Int) -> String {
    value < 10 ? "0\(value)" : String(value)
}

extension Date {
    public init(epochMs: EpochMs) {
        self.init(timeIntervalSince1970: Double(epochMs) / 1_000)
    }

    public var epochMs: EpochMs {
        EpochMs((timeIntervalSince1970 * 1_000).rounded())
    }
}

public func epochNow() -> EpochMs {
    Date().epochMs
}

/// The local calendar date containing `ts`.
public func dateKeyOf(_ ts: EpochMs, in zone: TimeZone = .current) -> DateKey {
    let comps = calendar(in: zone).dateComponents([.year, .month, .day], from: Date(epochMs: ts))
    return DateKey(unchecked: comps.year!, month: comps.month!, day: comps.day!)
}

public func isDateKey(_ value: String) -> Bool {
    DateKey(value) != nil
}

/// Midnight (00:00:00.000 local) at the start of the given date key.
///
/// On a spring-forward DST day in zones where the transition happens *at* midnight
/// (e.g. America/Santiago), local midnight does not exist; the resolved 01:00 is the
/// correct start-of-day instant for our purposes.
public func startOfDay(_ date: DateKey, in zone: TimeZone = .current) -> EpochMs {
    let comps = DateComponents(
        year: date.year, month: date.month, day: date.day,
        hour: 0, minute: 0, second: 0
    )
    return calendar(in: zone).date(from: comps)!.epochMs
}

/// Midnight at the start of the local day containing `ts`.
public func startOfDayAt(_ ts: EpochMs, in zone: TimeZone = .current) -> EpochMs {
    startOfDay(dateKeyOf(ts, in: zone), in: zone)
}

/// The instant the given local day ends — i.e. the start of the next day.
public func endOfDay(_ date: DateKey, in zone: TimeZone = .current) -> EpochMs {
    startOfDay(addDays(date, 1), in: zone)
}

/// Start of the next local day after `ts`. Handles 23h/25h DST days.
public func nextMidnightAfter(_ ts: EpochMs, in zone: TimeZone = .current) -> EpochMs {
    endOfDay(dateKeyOf(ts, in: zone), in: zone)
}

private func gmtNoon(_ date: DateKey) -> Date {
    gmtCalendar.date(from: DateComponents(
        year: date.year, month: date.month, day: date.day, hour: 12
    ))!
}

private func key(of gmtDate: Date) -> DateKey {
    let comps = gmtCalendar.dateComponents([.year, .month, .day], from: gmtDate)
    return DateKey(unchecked: comps.year!, month: comps.month!, day: comps.day!)
}

/// Shift a date key by whole calendar days.
public func addDays(_ date: DateKey, _ days: Int) -> DateKey {
    key(of: gmtCalendar.date(byAdding: .day, value: days, to: gmtNoon(date))!)
}

/// Whole calendar days from `from` to `to`; negative when `to` precedes `from`.
public func daysBetween(from: DateKey, to: DateKey) -> Int {
    gmtCalendar.dateComponents([.day], from: gmtNoon(from), to: gmtNoon(to)).day!
}

/// Every date key from `from` to `to`, inclusive. Empty when `to` precedes `from`.
public func eachDay(from: DateKey, to: DateKey) -> [DateKey] {
    let span = daysBetween(from: from, to: to)
    if span < 0 { return [] }
    return (0...span).map { addDays(from, $0) }
}

public func todayKey(now: EpochMs? = nil, in zone: TimeZone = .current) -> DateKey {
    dateKeyOf(now ?? epochNow(), in: zone)
}

// MARK: - Week / month ranges

public enum WeekStart: Int, Sendable, Codable {
    case sunday = 0
    case monday = 1
}

/// The date key of the first day of the week containing `date`.
public func startOfWeek(_ date: DateKey, weekStartsOn: WeekStart) -> DateKey {
    // Calendar weekdays are 1 (Sunday) through 7; shift to JS getDay()'s 0-based form.
    let dow = gmtCalendar.component(.weekday, from: gmtNoon(date)) - 1
    let delta = (dow - weekStartsOn.rawValue + 7) % 7
    return addDays(date, -delta)
}

public func endOfWeek(_ date: DateKey, weekStartsOn: WeekStart) -> DateKey {
    addDays(startOfWeek(date, weekStartsOn: weekStartsOn), 6)
}

public func startOfMonth(_ date: DateKey) -> DateKey {
    DateKey(unchecked: date.year, month: date.month, day: 1)
}

public func endOfMonth(_ date: DateKey) -> DateKey {
    let days = gmtCalendar.range(of: .day, in: .month, for: gmtNoon(date))!.count
    return DateKey(unchecked: date.year, month: date.month, day: days)
}

// MARK: - Formatting

/// `H:MM` — the menu-bar format. Hours are not zero-padded and are not wrapped
/// at 24. Negative inputs clamp to zero.
public func formatHM(_ ms: Int64) -> String {
    let total = max(0, floorDiv(ms, MS_PER_MINUTE))
    return "\(total / 60):\(pad2(Int(total % 60)))"
}

/// `H:MM:SS`, for the big live timer.
public func formatHMS(_ ms: Int64) -> String {
    let total = max(0, floorDiv(ms, MS_PER_SECOND))
    let h = total / 3_600
    let m = (total % 3_600) / 60
    let s = total % 60
    return "\(h):\(pad2(Int(m))):\(pad2(Int(s)))"
}

/// `1h 24m`, or `24m` under an hour, or `0m` when empty.
public func formatCompact(_ ms: Int64) -> String {
    let total = max(0, floorDiv(ms, MS_PER_MINUTE))
    let h = total / 60
    let m = total % 60
    if h == 0 { return "\(m)m" }
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

private func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
    let q = value / divisor
    return value % divisor != 0 && (value < 0) != (divisor < 0) ? q - 1 : q
}

/// Local wall-clock `HH:MM` for an instant.
public func formatClock(_ ts: EpochMs, in zone: TimeZone = .current) -> String {
    let comps = calendar(in: zone).dateComponents([.hour, .minute], from: Date(epochMs: ts))
    return "\(pad2(comps.hour!)):\(pad2(comps.minute!))"
}

/// Local wall-clock `HH:MM:SS` for an instant.
public func formatClockSeconds(_ ts: EpochMs, in zone: TimeZone = .current) -> String {
    let comps = calendar(in: zone).dateComponents(
        [.hour, .minute, .second], from: Date(epochMs: ts)
    )
    return "\(pad2(comps.hour!)):\(pad2(comps.minute!)):\(pad2(comps.second!))"
}

/// `Mon 4 Aug 2025`, using the locale's month/weekday names.
public func formatDateLong(_ date: DateKey, locale: Locale = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = gmtCalendar
    formatter.timeZone = gmtCalendar.timeZone
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate("EEE d MMM y")
    return formatter.string(from: gmtNoon(date))
}

/// `HH:MM` for a local time-of-day input field.
public func toTimeInputValue(_ ts: EpochMs, in zone: TimeZone = .current) -> String {
    formatClock(ts, in: zone)
}

/// Combine a date key with an `HH:MM` (or `HH:MM:SS`) local time into an instant.
/// Returns `nil` when the time string is malformed.
public func fromTimeInputValue(
    date: DateKey, time: String, in zone: TimeZone = .current
) -> EpochMs? {
    // `components(separatedBy:)` keeps empty components, so "09:" and ":30" stay
    // rejectable — `split(separator:)` would silently drop them.
    let parts = time.components(separatedBy: ":")
    guard parts.count >= 2, parts.count <= 3 else { return nil }
    let hh = parts[0]
    let mm = parts[1]
    let ss = parts.count == 3 ? parts[2] : "0"
    // One or two plain digits — no sign, no radix prefix, no exponent, no whitespace.
    for component in [hh, mm, ss] where component.wholeMatch(of: /\d{1,2}/) == nil {
        return nil
    }
    let h = Int(hh)!
    let m = Int(mm)!
    let s = Int(ss)!
    guard h <= 23, m <= 59, s <= 59 else { return nil }
    let comps = DateComponents(
        year: date.year, month: date.month, day: date.day,
        hour: h, minute: m, second: s
    )
    return calendar(in: zone).date(from: comps)!.epochMs
}
