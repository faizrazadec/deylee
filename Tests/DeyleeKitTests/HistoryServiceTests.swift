import Foundation
import Testing
@testable import DeyleeKit

/// Manual edits from the History window, against a real SQLite file.
///
/// These pin the rules a hand edit shares with the timer: one row per local day, no
/// overlaps, at most one open segment — and the exact messages the user reads when an
/// edit is refused. The zone is pinned to Europe/Berlin so midnight is a fixed instant.

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

@MainActor
private final class Harness {
    let repo: Repository
    let service: HistoryService
    let prefs: PreferencesStore
    let db: Database
    private let path: String
    private var clock: EpochMs

    init(now: EpochMs, dailyTargetHours: Double = 8) throws {
        path = NSTemporaryDirectory() + "deylee-history-\(UUID().uuidString).sqlite"
        db = try openDatabase(at: path)
        try runMigrations(db)
        repo = Repository(db: db, in: berlin)
        prefs = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        prefs.set(\.dailyTargetHours, to: dailyTargetHours)
        clock = now
        var readClock: () -> EpochMs = { now }
        service = HistoryService(repo: repo, prefs: prefs, in: berlin, now: { readClock() })
        readClock = { [weak self] in self?.clock ?? now }
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Seeds a closed segment the way the timer would have written it.
    @discardableResult
    func seed(
        _ date: String, type: SegmentType = .work, from: EpochMs, to: EpochMs?, note: String? = nil
    ) throws -> Segment {
        let day = try repo.getOrCreateDay(key(date), targetMinutes: 480, now: clock)
        return try repo.insertSegment(
            dayId: day.id, type: type, startedAt: from, endedAt: to, note: note, now: clock
        )
    }

    func segments(_ date: String) throws -> [Segment] {
        try repo.dayDetail(key(date), now: clock)?.segments ?? []
    }
}

@Suite @MainActor struct HistoryServiceCreate {
    @Test func storesASegmentAndReturnsTheAddressedDay() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let outcome = try h.service.createSegment(
            on: key("2025-08-04"),
            CreateSegmentInput(
                type: .work,
                startedAt: local(2025, 8, 4, 9),
                endedAt: local(2025, 8, 4, 12),
                note: "spec"
            )
        )

        #expect(outcome.detail?.day.date == key("2025-08-04"))
        #expect(outcome.detail?.totals.workedMs == 3 * MS_PER_HOUR)
        #expect(outcome.affectedDates == [key("2025-08-04")])
        #expect(try h.segments("2025-08-04").first?.note == "spec")
    }

    @Test func splitsAtMidnightIntoOneRowPerDay() throws {
        let h = try Harness(now: local(2025, 8, 5, 9))
        let outcome = try h.service.createSegment(
            on: key("2025-08-04"),
            CreateSegmentInput(
                type: .work,
                startedAt: local(2025, 8, 4, 22),
                endedAt: local(2025, 8, 5, 1),
                note: "overnight"
            )
        )

        let first = try h.segments("2025-08-04")
        let second = try h.segments("2025-08-05")
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].endedAt == local(2025, 8, 5, 0))
        #expect(second[0].startedAt == local(2025, 8, 5, 0))
        // The note described the whole span, so the tail keeps it too.
        #expect(second[0].note == "overnight")
        #expect(outcome.affectedDates == [key("2025-08-04"), key("2025-08-05")])
        #expect(outcome.detail?.day.date == key("2025-08-04"))
    }

    @Test func refusesAnOverlapWithTheClashingTimes() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))

        #expect(throws: MutationError(
            code: .overlap, message: "Overlaps the work segment from 09:00 to 12:00."
        )) {
            try h.service.createSegment(
                on: key("2025-08-04"),
                CreateSegmentInput(
                    type: .break,
                    startedAt: local(2025, 8, 4, 11),
                    endedAt: local(2025, 8, 4, 13)
                )
            )
        }
    }

    @Test func validatesAgainstTheDayTheTailLandsOn() throws {
        let h = try Harness(now: local(2025, 8, 5, 9))
        // The next morning's work is invisible to the addressed day, which is exactly
        // why every affected day is checked.
        try h.seed("2025-08-05", from: local(2025, 8, 5, 0, 30), to: local(2025, 8, 5, 8))

        #expect(throws: MutationError.self) {
            try h.service.createSegment(
                on: key("2025-08-04"),
                CreateSegmentInput(
                    type: .work,
                    startedAt: local(2025, 8, 4, 22),
                    endedAt: local(2025, 8, 5, 1)
                )
            )
        }
        #expect(try h.segments("2025-08-04").isEmpty)
    }

    @Test func touchingEndpointsAreNotAnOverlap() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))

        // Intervals are half-open, so a pause boundary is a touch, not a clash.
        let outcome = try h.service.createSegment(
            on: key("2025-08-04"),
            CreateSegmentInput(
                type: .break,
                startedAt: local(2025, 8, 4, 12),
                endedAt: local(2025, 8, 4, 12, 30)
            )
        )
        #expect(outcome.detail?.totals.segmentCount == 2)
    }

    @Test func createsTheAddressedDayEvenWhenEveryPieceLandsElsewhere() throws {
        let h = try Harness(now: local(2025, 8, 5, 9))
        let outcome = try h.service.createSegment(
            on: key("2025-08-04"),
            CreateSegmentInput(
                type: .work,
                startedAt: local(2025, 8, 5, 9),
                endedAt: local(2025, 8, 5, 10)
            )
        )
        // The window gets back the day it was editing, even though it is now empty.
        #expect(outcome.detail?.day.date == key("2025-08-04"))
        #expect(outcome.detail?.segments.isEmpty == true)
        #expect(try h.segments("2025-08-05").count == 1)
    }
}

@Suite @MainActor struct HistoryServiceUpdate {
    @Test func editsInPlaceWhenTheDayDoesNotChange() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let seeded = try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))

        let outcome = try h.service.updateSegment(UpdateSegmentInput(
            id: seeded.id,
            type: .break,
            startedAt: local(2025, 8, 4, 9, 30),
            endedAt: .some(local(2025, 8, 4, 10)),
            note: .some("shorter")
        ))

        let stored = try h.segments("2025-08-04")
        #expect(stored.count == 1)
        #expect(stored[0].id == seeded.id)
        #expect(stored[0].type == .break)
        #expect(stored[0].note == "shorter")
        #expect(outcome.detail?.totals.breakMs == 30 * MS_PER_MINUTE)
    }

    @Test func absentFieldsAreUntouched() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let seeded = try h.seed(
            "2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12), note: "kept"
        )

        try h.service.updateSegment(UpdateSegmentInput(
            id: seeded.id, startedAt: local(2025, 8, 4, 10)
        ))

        let stored = try h.segments("2025-08-04")[0]
        #expect(stored.note == "kept")
        #expect(stored.type == .work)
        #expect(stored.endedAt == local(2025, 8, 4, 12))
    }

    @Test func movingToAnotherDayRefilesTheRow() throws {
        let h = try Harness(now: local(2025, 8, 5, 18))
        let seeded = try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))

        let outcome = try h.service.updateSegment(UpdateSegmentInput(
            id: seeded.id,
            startedAt: local(2025, 8, 5, 9),
            endedAt: .some(local(2025, 8, 5, 12))
        ))

        // Rows never move between days: the old one goes and a new one is filed.
        #expect(try h.segments("2025-08-04").isEmpty)
        let moved = try h.segments("2025-08-05")
        #expect(moved.count == 1)
        #expect(moved[0].id != seeded.id)
        #expect(outcome.detail?.day.date == key("2025-08-05"))
        // The original day's totals changed too, so it is invalidated alongside.
        #expect(outcome.affectedDates.contains(key("2025-08-04")))
        #expect(outcome.affectedDates.contains(key("2025-08-05")))
    }

    @Test func stretchingPastMidnightSplitsAndKeepsTheHeadInPlace() throws {
        let h = try Harness(now: local(2025, 8, 5, 9))
        let seeded = try h.seed("2025-08-04", from: local(2025, 8, 4, 22), to: local(2025, 8, 4, 23))

        let outcome = try h.service.updateSegment(UpdateSegmentInput(
            id: seeded.id, endedAt: .some(local(2025, 8, 5, 1))
        ))

        let head = try h.segments("2025-08-04")
        let tail = try h.segments("2025-08-05")
        #expect(head.count == 1)
        #expect(head[0].id == seeded.id)
        #expect(head[0].endedAt == local(2025, 8, 5, 0))
        #expect(tail.count == 1)
        #expect(tail[0].endedAt == local(2025, 8, 5, 1))
        #expect(outcome.detail?.day.date == key("2025-08-04"))
    }

    @Test func excludesTheEditedRowFromItsOwnOverlapCheck() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let seeded = try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))

        // Shrinking a segment necessarily overlaps its own former self.
        let outcome = try h.service.updateSegment(UpdateSegmentInput(
            id: seeded.id, endedAt: .some(local(2025, 8, 4, 11))
        ))
        #expect(outcome.detail?.totals.workedMs == 2 * MS_PER_HOUR)
    }

    @Test func refusesReopeningWhileAnotherSegmentIsOpen() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let closed = try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))
        try h.seed("2025-08-04", from: local(2025, 8, 4, 13), to: nil)

        #expect(throws: MutationError(
            code: .openSegmentConflict, message: "Another segment is still running."
        )) {
            try h.service.updateSegment(UpdateSegmentInput(id: closed.id, endedAt: .some(nil)))
        }
    }

    @Test func reportsAMissingRow() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        #expect(throws: MutationError(
            code: .notFound, message: "That segment no longer exists."
        )) {
            try h.service.updateSegment(UpdateSegmentInput(id: 404, startedAt: local(2025, 8, 4, 9)))
        }
    }

    @Test func aRejectedEditWritesNothing() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let first = try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))
        try h.seed("2025-08-04", from: local(2025, 8, 4, 13), to: local(2025, 8, 4, 15))

        #expect(throws: MutationError.self) {
            try h.service.updateSegment(UpdateSegmentInput(
                id: first.id, endedAt: .some(local(2025, 8, 4, 14))
            ))
        }
        #expect(try h.segments("2025-08-04")[0].endedAt == local(2025, 8, 4, 12))
    }
}

@Suite @MainActor struct HistoryServiceDelete {
    @Test func removesAClosedSegmentAndReturnsItsDay() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let seeded = try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: local(2025, 8, 4, 12))

        let outcome = try h.service.deleteSegment(seeded.id)
        #expect(outcome.affectedDates == [key("2025-08-04")])
        #expect(outcome.detail?.totals.segmentCount == 0)
        #expect(try h.segments("2025-08-04").isEmpty)
    }

    @Test func refusesTheSegmentTheTimerIsStillWritingTo() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        let open = try h.seed("2025-08-04", from: local(2025, 8, 4, 9), to: nil)

        #expect(throws: MutationError(
            code: .openSegmentConflict,
            message: "Stop the timer before deleting the segment it is still writing to."
        )) {
            try h.service.deleteSegment(open.id)
        }
        #expect(try h.segments("2025-08-04").count == 1)
    }

    @Test func reportsAMissingRow() throws {
        let h = try Harness(now: local(2025, 8, 4, 18))
        #expect(throws: MutationError(
            code: .notFound, message: "That segment no longer exists."
        )) {
            try h.service.deleteSegment(404)
        }
    }
}
