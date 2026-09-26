import Foundation
import Testing
@testable import DeyleeKit

/// Past days are locked: two hours after their midnight, judged by the server's time.
///
/// What breaks if these fail: a day that locks at the wrong instant on a 23- or 25-hour
/// day, a Mac whose date was set back reopening yesterday, and — the opposite failure —
/// a note that can no longer be fixed, or today's segments refused.

private let berlin = TimeZone(identifier: "Europe/Berlin")!
private let santiago = TimeZone(identifier: "America/Santiago")!

private func instant(
    _ zone: TimeZone, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0
) -> EpochMs {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.epochMs
}

private func key(_ s: String) -> DateKey { DateKey(s)! }

@Suite struct DayLockInstant {
    /// Built from calendar components on the next day, never by adding 24 hours: the day
    /// before a DST change is 23 or 25 hours long and a fixed offset lands an hour out.
    @Test(arguments: [
        ("2026-03-28", (2026, 3, 29)),  // an ordinary day
        ("2026-03-29", (2026, 3, 30)),  // 23 hours
        ("2026-10-25", (2026, 10, 26)), // 25 hours
    ])
    func locksTwoHoursAfterTheNextMidnight(date: String, next: (Int, Int, Int)) {
        let expected = instant(berlin, next.0, next.1, next.2, 2)
        #expect(dayLockInstant(key(date), in: berlin) == expected)
    }

    /// Chile moves its clocks at midnight, so 6 September 2026 has no 00:00. The day still
    /// ends where the calendar says the next one starts, and locks two hours of real time
    /// after that.
    @Test func aMidnightThatDoesNotExistStillEndsTheDay() {
        let nextStart = startOfDay(key("2026-09-06"), in: santiago)
        #expect(dayLockInstant(key("2026-09-05"), in: santiago) == nextStart + dayLockGraceMs)
        #expect(nextStart == instant(santiago, 2026, 9, 6, 1), "the day starts at 01:00")
    }

    @Test func theGracePeriodIsTheOnlyTimeYesterdayStaysOpen() {
        let yesterday = key("2026-06-10")
        #expect(!isDayLocked(yesterday, now: instant(berlin, 2026, 6, 11, 1, 59), in: berlin))
        #expect(isDayLocked(yesterday, now: instant(berlin, 2026, 6, 11, 2), in: berlin))
        #expect(!isDayLocked(key("2026-06-11"), now: instant(berlin, 2026, 6, 11, 23, 59), in: berlin))
    }
}

@Suite @MainActor struct TrustedClockTests {
    /// A clock whose wall and monotonic readings the test moves by hand.
    private final class Hands {
        var wall: EpochMs = 1_000_000
        var elapsed: Duration = .seconds(50)
    }

    @Test func beforeAnySyncItIsTheWallClock() {
        let hands = Hands()
        let clock = TrustedClock(wall: { hands.wall }, elapsed: { hands.elapsed })
        #expect(clock.now() == 1_000_000)
    }

    /// The whole point: after a sync, setting the Mac's date back moves nothing.
    @Test func afterASyncTheWallClockNoLongerCounts() {
        let hands = Hands()
        let clock = TrustedClock(wall: { hands.wall }, elapsed: { hands.elapsed })
        clock.anchor(serverTime: 5_000_000)

        hands.wall -= 86_400_000  // yesterday, as far as the Mac is concerned
        hands.elapsed += .milliseconds(1_500)
        #expect(clock.now() == 5_001_500)
    }
}

// MARK: - The History window

@MainActor
private final class Harness {
    let repo: Repository
    let service: HistoryService
    private let path: String

    /// `wall` is what this Mac's clock says; `trusted` is the server's time.
    init(wall: EpochMs, trusted: EpochMs) throws {
        path = NSTemporaryDirectory() + "deylee-lock-\(UUID().uuidString).sqlite"
        let db = try openDatabase(at: path)
        try runMigrations(db)
        repo = Repository(db: db, in: berlin)
        let prefs = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        service = HistoryService(
            repo: repo, prefs: prefs, in: berlin, now: { wall }, trustedNow: { trusted }
        )
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    func seed(_ date: String, from: EpochMs, to: EpochMs) throws -> Segment {
        let day = try repo.getOrCreateDay(key(date), targetMinutes: 480, now: from)
        return try repo.insertSegment(
            dayId: day.id, type: .work, startedAt: from, endedAt: to, now: from
        )
    }
}

@Suite @MainActor struct HistoryOnALockedDay {
    private let june10 = "2026-06-10"
    private let nine = instant(berlin, 2026, 6, 10, 9)
    private let noon = instant(berlin, 2026, 6, 10, 12)
    /// Three days later, by both clocks.
    private let later = instant(berlin, 2026, 6, 13, 10)

    private func expectLocked(_ body: () throws -> Void) {
        #expect(throws: MutationError(code: .locked, message: dayLockedMessage), performing: body)
    }

    @Test func refusesANewSegment() throws {
        let h = try Harness(wall: later, trusted: later)
        expectLocked {
            _ = try h.service.createSegment(
                on: key(june10),
                CreateSegmentInput(type: .work, startedAt: nine, endedAt: noon)
            )
        }
    }

    @Test func refusesNewTimesAndANewType() throws {
        let h = try Harness(wall: later, trusted: later)
        let seg = try h.seed(june10, from: nine, to: noon)
        expectLocked { _ = try h.service.updateSegment(UpdateSegmentInput(id: seg.id, endedAt: .some(noon + 60_000))) }
        expectLocked { _ = try h.service.updateSegment(UpdateSegmentInput(id: seg.id, type: .break)) }
    }

    @Test func refusesADelete() throws {
        let h = try Harness(wall: later, trusted: later)
        let seg = try h.seed(june10, from: nine, to: noon)
        expectLocked { _ = try h.service.deleteSegment(seg.id) }
    }

    @Test func stillTakesANote() throws {
        let h = try Harness(wall: later, trusted: later)
        let seg = try h.seed(june10, from: nine, to: noon)
        let outcome = try h.service.updateSegment(UpdateSegmentInput(id: seg.id, note: .some("standup")))
        #expect(outcome.detail?.segments.first?.note == "standup")
    }

    /// A Mac set back to 10 June thinks it is still that day. The server's time says
    /// otherwise, and that is the one asked.
    @Test func aDateSetBackOnThisMacDoesNotReopenTheDay() throws {
        let h = try Harness(wall: instant(berlin, 2026, 6, 10, 18), trusted: later)
        let seg = try h.seed(june10, from: nine, to: noon)
        expectLocked { _ = try h.service.deleteSegment(seg.id) }
    }

    @Test func todayIsNotLocked() throws {
        let h = try Harness(wall: noon + 3_600_000, trusted: noon + 3_600_000)
        let seg = try h.seed(june10, from: nine, to: noon)
        _ = try h.service.updateSegment(UpdateSegmentInput(id: seg.id, endedAt: .some(noon + 60_000)))
        _ = try h.service.deleteSegment(seg.id)
    }
}

// MARK: - Putting back what the server refused

@Suite struct RestoreFromServer {
    @Test func theServersCopyReplacesANewerLocalEditAndLeavesItClean() throws {
        let path = NSTemporaryDirectory() + "deylee-restore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try openDatabase(at: path)
        try runMigrations(db)
        let repo = Repository(db: db, in: berlin)

        let uuid = UUID().uuidString.lowercased()
        let server = SyncSegment(
            uuid: uuid, dayDate: key("2026-06-10"), type: .work,
            startedAt: 1_000, endedAt: 2_000, note: "kept",
            createdAt: 1_000, updatedAt: 3_000
        )
        try repo.applyRemote(days: [], segments: [server], serverSeq: 1)
        // The edit the server refused: newer, so last-write-wins alone would keep it.
        try db.run(
            "UPDATE segments SET ended_at = 9_000, note = 'mine', updated_at = 9_000, dirty = 1 WHERE uuid = ?",
            [.text(uuid)]
        )
        try repo.markRejected([(uuid, 9_000, "locked")], table: .segments)

        try repo.restoreFromServer([server])

        let row = try db.queryOne(
            "SELECT ended_at, note, dirty, rejected_at FROM segments WHERE uuid = ?", [.text(uuid)]
        ) { ($0.optionalInt64(0), $0.optionalText(1), $0.int(2), $0.optionalInt64(3)) }
        #expect(row?.0 == 2_000, "the server's end, not the edit's")
        #expect(row?.1 == "kept")
        #expect(row?.2 == 0, "not pushed back")
        #expect(row?.3 == nil, "no longer shown as refused")
    }
}
