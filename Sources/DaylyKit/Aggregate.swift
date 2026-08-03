import Foundation

/// Range roll-ups for the History window: week totals, month totals, daily average.
///
/// Ported from `src/domain/aggregate.ts`. Everything here is pure calendar
/// arithmetic on `DateKey`s, which `Time.swift` resolves on a fixed GMT calendar,
/// so none of these functions needs a `TimeZone`: a week is seven date keys long
/// whether or not a DST transition falls inside it.

/// Summarise a set of days.
///
/// The daily average deliberately divides by *active* days — days with recorded work
/// — not by calendar days in the range, so a month average is not dragged down by
/// weekends and holidays.
public func summariseRange(_ range: DateRange, days: [DayDetail]) -> RangeSummary {
    var totalWorkedMs: Int64 = 0
    var totalBreakMs: Int64 = 0
    var activeDayCount = 0
    var targetMetCount = 0

    for detail in days {
        totalWorkedMs += detail.totals.workedMs
        totalBreakMs += detail.totals.breakMs
        if detail.totals.workedMs > 0 {
            activeDayCount += 1
            let targetMs = Int64(detail.day.targetMinutes) * MS_PER_MINUTE
            // A day with no target set can never "meet" it, however long it was.
            if targetMs > 0 && detail.totals.workedMs >= targetMs { targetMetCount += 1 }
        }
    }

    return RangeSummary(
        range: range,
        days: days,
        totalWorkedMs: totalWorkedMs,
        totalBreakMs: totalBreakMs,
        activeDayCount: activeDayCount,
        averageWorkedMsPerActiveDay: activeDayCount == 0
            ? 0
            : totalWorkedMs / Int64(activeDayCount),
        targetMetCount: targetMetCount
    )
}

/// One calendar day of a densified range: the date, and the data for it if any.
public struct DenseDay: Equatable, Sendable {
    public let date: DateKey
    /// `nil` when the range covers this day but nothing was recorded on it.
    public let detail: DayDetail?

    public init(date: DateKey, detail: DayDetail?) {
        self.date = date
        self.detail = detail
    }
}

/// Every calendar day of a range, in order, carrying `nil` where there is no data.
///
/// The TypeScript version returns an insertion-ordered `Map`. Swift's `Dictionary`
/// has no order and a calendar grid depends on it, so the ordered `entries` array is
/// the primary representation; the by-date lookups the `Map` gave for free are kept
/// as `contains(_:)` and `subscript(_:)`.
public struct DenseRange: Equatable, Sendable, RandomAccessCollection {
    /// One entry per calendar day of the range, ascending.
    public let entries: [DenseDay]
    private let indexByDate: [DateKey: Int]

    init(entries: [DenseDay]) {
        self.entries = entries
        var index: [DateKey: Int] = [:]
        for (position, entry) in entries.enumerated() { index[entry.date] = position }
        self.indexByDate = index
    }

    public var dates: [DateKey] { entries.map(\.date) }

    /// True when the range covers `date` at all — the distinction `subscript` cannot
    /// make, since a covered day with no data also reads as `nil`.
    public func contains(_ date: DateKey) -> Bool { indexByDate[date] != nil }

    /// The data for `date`, or `nil` both when the day is empty and when it lies
    /// outside the range. Pair with `contains(_:)` when the difference matters.
    public subscript(date: DateKey) -> DayDetail? {
        guard let position = indexByDate[date] else { return nil }
        return entries[position].detail
    }

    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }
    public subscript(position: Int) -> DenseDay { entries[position] }
}

/// Fill in placeholders so a calendar grid has an entry for every day.
public func densifyRange(_ range: DateRange, days: [DayDetail]) -> DenseRange {
    var byDate: [DateKey: DayDetail] = [:]
    for detail in days { byDate[detail.day.date] = detail }

    return DenseRange(entries: eachDay(from: range.from, to: range.to).map { date in
        DenseDay(date: date, detail: byDate[date])
    })
}

public func weekRange(_ date: DateKey, weekStartsOn: WeekStart) -> DateRange {
    DateRange(
        from: startOfWeek(date, weekStartsOn: weekStartsOn),
        to: endOfWeek(date, weekStartsOn: weekStartsOn)
    )
}

public func monthRange(_ date: DateKey) -> DateRange {
    DateRange(from: startOfMonth(date), to: endOfMonth(date))
}

/// Totals for a sub-range — typically the week containing a date — taken from an
/// already-loaded, wider set of days rather than a second query.
public func subRange(_ days: [DayDetail], range: DateRange) -> RangeSummary {
    summariseRange(range, days: days.filter { $0.day.date >= range.from && $0.day.date <= range.to })
}
