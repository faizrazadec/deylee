import Foundation
import Testing
@testable import DeyleeKit

/// The export column set is a public contract — somebody has a spreadsheet built on it —
/// so these pin the exact bytes rather than "roughly this shape".
///
/// The zone is pinned to Europe/Berlin so the local wall-clock columns are exact wherever
/// the suite runs.

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private func local(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0
) -> EpochMs {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = berlin
    return cal.date(from: DateComponents(
        year: y, month: m, day: d, hour: h, minute: min, second: s
    ))!.epochMs
}

private func key(_ s: String) -> DateKey { DateKey(s)! }

private func segment(
    id: Int64, dayId: Int64 = 1, type: SegmentType = .work,
    from: EpochMs, to: EpochMs?, note: String? = nil
) -> Segment {
    Segment(
        id: id, dayId: dayId, type: type, startedAt: from, endedAt: to, note: note,
        createdAt: from, updatedAt: from
    )
}

private func detail(
    _ date: String, id: Int64 = 1, targetMinutes: Int = 480, segments: [Segment]
) -> DayDetail {
    let day = Day(id: id, date: key(date), createdAt: 0, endedAt: nil, targetMinutes: targetMinutes)
    return DayDetail(
        day: day, segments: segments,
        totals: dayTotals(segments, key(date), now: local(2025, 8, 4, 18), in: berlin)
    )
}

@Suite struct HistoryCsvExport {
    @Test func headerIsExact() {
        let csv = buildHistoryCsv([], in: berlin)
        #expect(csv == "date,segment_type,started_at_local,ended_at_local,duration_minutes,started_at_utc_ms,ended_at_utc_ms,note")
    }

    @Test func writesOneRowPerSegmentWithBothClocks() {
        let start = local(2025, 8, 4, 9, 0)
        let end = local(2025, 8, 4, 10, 0)
        let csv = buildHistoryCsv(
            [detail("2025-08-04", segments: [segment(id: 7, from: start, to: end)])],
            in: berlin
        )
        let lines = csv.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[1] == "2025-08-04,work,09:00:00,10:00:00,60,\(start),\(end),")
    }

    @Test func durationKeepsTwoDecimalsAndDropsTrailingZeros() {
        let start = local(2025, 8, 4, 9, 0)
        // 40 seconds: whole minutes would report this as 0, which reads as a bug.
        let csv = buildHistoryCsv(
            [detail("2025-08-04", segments: [segment(id: 1, from: start, to: start + 40_000)])],
            in: berlin
        )
        #expect(csv.components(separatedBy: "\n")[1].contains(",0.67,"))
    }

    @Test func openSegmentLeavesEndAndDurationEmpty() {
        let start = local(2025, 8, 4, 9, 0)
        let csv = buildHistoryCsv(
            [detail("2025-08-04", segments: [segment(id: 1, from: start, to: nil)])],
            in: berlin
        )
        // "now" is never baked into a file: it would be wrong the moment it is written.
        #expect(csv.components(separatedBy: "\n")[1] == "2025-08-04,work,09:00:00,,,\(start),,")
    }

    @Test func dayWithNoSegmentsStillGetsARow() {
        let csv = buildHistoryCsv([detail("2025-08-04", segments: [])], in: berlin)
        #expect(csv.components(separatedBy: "\n")[1] == "2025-08-04,,,,,,,")
    }

    @Test func quotesOnlyFieldsThatNeedIt() {
        let start = local(2025, 8, 4, 9, 0)
        let csv = buildHistoryCsv(
            [detail("2025-08-04", segments: [
                segment(id: 1, from: start, to: start + 60_000, note: "a, b"),
                segment(id: 2, from: start + 120_000, to: start + 180_000, note: "say \"hi\""),
                segment(id: 3, from: start + 240_000, to: start + 300_000, note: "plain"),
            ])],
            in: berlin
        )
        let lines = csv.components(separatedBy: "\n")
        #expect(lines[1].hasSuffix(",\"a, b\""))
        #expect(lines[2].hasSuffix(",\"say \"\"hi\"\"\""))
        #expect(lines[3].hasSuffix(",plain"))
    }

    @Test func daysAscendingSegmentsAscendingNoTrailingNewline() {
        let day1 = local(2025, 8, 4, 9, 0)
        let day2 = local(2025, 8, 5, 9, 0)
        let csv = buildHistoryCsv(
            [
                detail("2025-08-05", id: 2, segments: [
                    segment(id: 9, dayId: 2, from: day2, to: day2 + 60_000),
                ]),
                detail("2025-08-04", segments: [
                    segment(id: 5, from: day1 + 60_000, to: day1 + 120_000),
                    segment(id: 4, from: day1, to: day1 + 60_000),
                ]),
            ],
            in: berlin
        )
        let lines = csv.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[1].hasPrefix("2025-08-04,work,09:00:00,"))
        #expect(lines[2].hasPrefix("2025-08-04,work,09:01:00,"))
        #expect(lines[3].hasPrefix("2025-08-05,"))
        #expect(!csv.hasSuffix("\n"))
    }
}

@Suite struct HistoryJsonExport {
    @Test func matchesTheDocumentedShape() {
        let start = local(2025, 8, 4, 9, 0)
        let json = buildHistoryJson(
            [detail("2025-08-04", segments: [
                segment(id: 3, from: start, to: start + 3_600_000, note: nil),
            ])],
            range: DateRange(from: key("2025-08-01"), to: key("2025-08-31")),
            exportedAt: 1_754_300_000_123
        )

        // ISO-8601 UTC with milliseconds, the shape `Date.toISOString()` produces.
        #expect(json.hasPrefix("{\n  \"exportedAt\": \"2025-08-04T09:33:20.123Z\",\n"))
        #expect(json.contains("  \"range\": {\n    \"from\": \"2025-08-01\",\n    \"to\": \"2025-08-31\"\n  },\n"))
        // Totals are computed at export time, not read from a stored counter.
        #expect(json.contains("\"workedMs\": 3600000"))
        #expect(json.contains("\"segmentCount\": 1"))
        #expect(json.contains("\"hasOpenSegment\": false"))
        #expect(json.contains("\"note\": null"))
        #expect(json.hasSuffix("\n}"))
    }

    @Test func emptyRangeStillCarriesItsBounds() {
        let json = buildHistoryJson(
            [], range: DateRange(from: key("2025-09-01"), to: key("2025-09-30")),
            exportedAt: 0
        )
        #expect(json.contains("\"days\": []"))
        #expect(json.contains("\"exportedAt\": \"1970-01-01T00:00:00.000Z\""))
    }

    @Test func escapesControlCharactersInNotes() {
        let start = local(2025, 8, 4, 9, 0)
        let json = buildHistoryJson(
            [detail("2025-08-04", segments: [
                segment(id: 1, from: start, to: start + 60_000, note: "line\nbreak \"q\""),
            ])],
            range: DateRange(from: key("2025-08-04"), to: key("2025-08-04")),
            exportedAt: 0
        )
        #expect(json.contains("\"note\": \"line\\nbreak \\\"q\\\"\""))
    }
}
