import Foundation
import Testing

@testable import DeyleeKit

/// What the app writes has to be what sync can send.
///
/// Every other sync test seeds its rows with raw SQL, which is right for exercising
/// states the writer cannot reach — a row already acknowledged, a cursor part-way
/// through a page. But it means none of them say anything about what the app itself
/// produces, and for a long time the answer was: rows with no `uuid`, which
/// `pendingPush` filters out. They were queued and unsendable at once, so the push
/// queue was empty on a machine full of tracked time and nothing anywhere failed.
///
/// These drive the real writer end to end and assert the rows reach the queue. That
/// is the assertion the sync suite was missing.
@Suite @MainActor struct SyncWriter {
    private static let zone = TimeZone(identifier: "Europe/Berlin")!
    /// A Wednesday, mid-morning, well away from any boundary.
    private static let morning: EpochMs = 1_754_899_200_000

    @MainActor
    private final class Harness {
        let repo: Repository
        let engine: TimerEngine
        let db: Database
        private let path: String
        private var clock: EpochMs

        init(now: EpochMs) throws {
            path = NSTemporaryDirectory() + "deylee-writer-\(UUID().uuidString).sqlite"
            db = try openDatabase(at: path)
            try runMigrations(db)
            repo = Repository(db: db, in: SyncWriter.zone)
            let prefs: PreferencesStore =
                DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
            clock = now
            var readClock: () -> EpochMs = { now }
            engine = TimerEngine(repo: repo, prefs: prefs, in: SyncWriter.zone, now: { readClock() })
            readClock = { [weak self] in self?.clock ?? now }
        }

        var now: EpochMs { clock }
        func advance(by ms: Int64) { clock += ms }

        deinit {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }

    /// The one assertion that would have caught all three omissions at once.
    @Test func trackingTimeQueuesItForTheServer() throws {
        let h = try Harness(now: Self.morning)
        _ = try h.engine.start()
        h.advance(by: 90 * 60 * 1000)
        _ = try h.engine.pause()

        let pending = try h.repo.pendingPush()
        #expect(pending.days.count == 1, "the day the timer opened must be queued")
        // Two: pausing closes the work segment and opens a break in the same move.
        #expect(pending.segments.count == 2, "both segments it wrote must be queued")
    }

    /// A uuid is the row's identity on the server. Without one the row cannot be
    /// referred to, so the push queue skips it — silently, and for ever.
    @Test func everyRowTheWriterCreatesHasAnIdentity() throws {
        let h = try Harness(now: Self.morning)
        _ = try h.engine.start()
        h.advance(by: 60 * 60 * 1000)
        _ = try h.engine.pause()

        let dayIDs = try h.db.query("SELECT uuid FROM days") { $0.optionalText(0) }
        let segIDs = try h.db.query("SELECT uuid FROM segments") { $0.optionalText(0) }
        #expect(!dayIDs.isEmpty && !segIDs.isEmpty)
        #expect(dayIDs.allSatisfy { $0 != nil }, "a day was written with no uuid")
        #expect(segIDs.allSatisfy { $0 != nil }, "a segment was written with no uuid")

        // UUIDv7, so ids sort in the order the rows were made and the server's pull
        // order agrees with this machine's insertion order without being told.
        let versionNibbles = (dayIDs + segIDs).compactMap { $0.map { Array($0)[14] } }
        #expect(versionNibbles.allSatisfy { $0 == "7" })
    }

    /// `markPushed` clears `dirty` once a row is acknowledged. An edit afterwards has
    /// to set it again or the correction never leaves the machine — the server keeps
    /// the old value and hands it back to every other device.
    @Test func anEditGoesUpAgainAfterItHasBeenPushed() throws {
        let h = try Harness(now: Self.morning)
        _ = try h.engine.start()
        h.advance(by: 60 * 60 * 1000)
        _ = try h.engine.pause()

        // Acknowledge everything, exactly as a successful push would.
        let queued = try h.repo.pendingPush()
        try h.repo.markPushed(queued.days.map { ($0.uuid, $0.updatedAt) }, table: .days)
        try h.repo.markPushed(queued.segments.map { ($0.uuid, $0.updatedAt) }, table: .segments)
        #expect(try h.repo.pendingPush().segments.isEmpty, "nothing should be pending yet")

        let dayID = try #require(try h.repo.findDay(dateKeyOf(h.now, in: Self.zone))).id
        let segment = try #require(try h.repo.listSegments(dayId: dayID).first)
        _ = try h.repo.updateSegmentFields(
            segment.id, UpdateSegmentInput(id: segment.id, note: "client meeting"), now: h.now
        )

        #expect(try h.repo.pendingPush().segments.count == 1, "the corrected row must go up")
    }

    /// A hard delete cannot be sent, because there is nothing left to send. The other
    /// devices never hear about it and hand the row straight back on the next pull.
    @Test func aDeleteSurvivesAsSomethingSendable() throws {
        let h = try Harness(now: Self.morning)
        _ = try h.engine.start()
        h.advance(by: 60 * 60 * 1000)
        _ = try h.engine.pause()

        let queued = try h.repo.pendingPush()
        try h.repo.markPushed(queued.days.map { ($0.uuid, $0.updatedAt) }, table: .days)
        try h.repo.markPushed(queued.segments.map { ($0.uuid, $0.updatedAt) }, table: .segments)

        let dayID = try #require(try h.repo.findDay(dateKeyOf(h.now, in: Self.zone))).id
        let segment = try #require(try h.repo.listSegments(dayId: dayID).first)
        #expect(try h.repo.deleteSegment(segment.id, now: h.now))

        let pending = try h.repo.pendingPush()
        #expect(pending.segments.count == 1, "the delete itself has to be sent")
        #expect(pending.segments.first?.deletedAt != nil, "and it must go up as a tombstone")
    }

    /// The other half of tombstoning: deleted time must vanish from the app, or the
    /// fix trades a sync bug for time that will not go away on screen.
    @Test func aTombstoneIsInvisibleToEveryReadPath() throws {
        let h = try Harness(now: Self.morning)
        _ = try h.engine.start()
        h.advance(by: 60 * 60 * 1000)
        _ = try h.engine.pause()

        let date = dateKeyOf(h.now, in: Self.zone)
        let dayID = try #require(try h.repo.findDay(date)).id
        let segment = try #require(try h.repo.listSegments(dayId: dayID).first)
        _ = try h.repo.deleteSegment(segment.id, now: h.now)

        // The break the pause opened is still there and should stay; only the row
        // that was deleted has to disappear.
        #expect(try h.repo.segment(id: segment.id) == nil, "segment(id:) still returns it")
        #expect(try !h.repo.listSegments(dayId: dayID).contains { $0.id == segment.id },
                "listSegments still returns it")
        #expect(try h.repo.dayDetail(date, now: h.now)?.segments
            .contains { $0.id == segment.id } == false, "dayDetail still returns it")
        let range = try h.repo.range(DateRange(from: date, to: date), now: h.now)
        #expect(range.first?.segments.contains { $0.id == segment.id } == false,
                "range still returns it")
        // Totals are derived by summing segments, so a tombstone left visible would
        // keep counting toward the day. The deleted row was the only work.
        #expect(range.first?.totals.workedMs == 0)
    }

    /// Deleting twice is not an error and not a second tombstone.
    @Test func deletingAnAlreadyDeletedSegmentReportsNothingHappened() throws {
        let h = try Harness(now: Self.morning)
        _ = try h.engine.start()
        h.advance(by: 60 * 60 * 1000)
        _ = try h.engine.pause()

        let dayID = try #require(try h.repo.findDay(dateKeyOf(h.now, in: Self.zone))).id
        let segment = try #require(try h.repo.listSegments(dayId: dayID).first)
        #expect(try h.repo.deleteSegment(segment.id, now: h.now))
        #expect(try h.repo.deleteSegment(segment.id, now: h.now) == false)
    }

    /// Ending the day is an edit to the day row like any other.
    @Test func endingTheDayQueuesTheDay() throws {
        let h = try Harness(now: Self.morning)
        _ = try h.engine.start()
        h.advance(by: 60 * 60 * 1000)
        _ = try h.engine.pause()

        let queued = try h.repo.pendingPush()
        try h.repo.markPushed(queued.days.map { ($0.uuid, $0.updatedAt) }, table: .days)
        try h.repo.markPushed(queued.segments.map { ($0.uuid, $0.updatedAt) }, table: .segments)

        let dayID = try #require(try h.repo.findDay(dateKeyOf(h.now, in: Self.zone))).id
        _ = try h.repo.setDayEnded(dayID, endedAt: h.now, now: h.now)
        #expect(try h.repo.pendingPush().days.count == 1, "End Day must reach the server")

        try h.repo.markPushed(
            try h.repo.pendingPush().days.map { ($0.uuid, $0.updatedAt) }, table: .days
        )
        _ = try h.repo.setDayTarget(dayID, targetMinutes: 300, now: h.now + 1)
        #expect(try h.repo.pendingPush().days.count == 1, "a changed target must too")
    }
}
