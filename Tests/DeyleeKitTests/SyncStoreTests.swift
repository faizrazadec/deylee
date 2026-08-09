import Foundation
import Testing

@testable import DeyleeKit

/// The local half of sync, exercised against a real SQLite file.
///
/// These are the decisions that cannot be tested against the server, because they
/// are about what this device chooses to send and what it does with what comes
/// back. Getting them wrong loses work quietly: a row that never goes up, an edit
/// overwritten by an older copy of itself, a delete that resurrects.

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private final class Harness {
    let repo: Repository
    let db: Database
    private let path: String

    init() throws {
        path = NSTemporaryDirectory() + "deylee-sync-\(UUID().uuidString).sqlite"
        db = try openDatabase(at: path)
        try runMigrations(db)
        repo = Repository(db: db, in: berlin)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// A day and one closed segment, written directly rather than through the writer.
    ///
    /// Deliberately raw SQL, and it used to claim it was "written the way the timer
    /// would" — which was not true, and hid the fact that the timer produced rows with
    /// no `uuid` that `pendingPush` silently skipped. Seeding by hand is still the
    /// right tool here, because these tests need states the writer cannot reach: a row
    /// already acknowledged, a tombstone, a cursor part-way through a page.
    ///
    /// What the writer itself produces is asserted in `SyncWriterTests`, which drives
    /// `TimerEngine` and checks the queue is not empty. Keep the two apart: the moment
    /// this helper is described as standing in for the app, it stops being a fixture
    /// and starts being a second, fictional writer.
    @discardableResult
    func seed(date: String, startedAt: EpochMs, endedAt: EpochMs) throws -> Int64 {
        try db.run(
            "INSERT INTO days (uuid, date, created_at, target_minutes, updated_at, dirty) VALUES (?, ?, ?, 480, ?, 1)",
            [.text(UUID().uuidString.lowercased()), .text(date), .integer(startedAt), .integer(startedAt)]
        )
        let dayID = db.lastInsertRowID
        try db.run(
            """
            INSERT INTO segments (uuid, day_id, type, started_at, ended_at, created_at, updated_at, dirty)
            VALUES (?, ?, 'work', ?, ?, ?, ?, 1)
            """,
            [.text(UUID().uuidString.lowercased()), .integer(dayID),
             .integer(startedAt), .integer(endedAt), .integer(startedAt), .integer(startedAt)]
        )
        return dayID
    }

    func dirtyCount(_ table: String) throws -> Int {
        try db.queryOne("SELECT count(*) FROM \(table) WHERE dirty = 1") { $0.int(0) } ?? -1
    }

    /// Takes a table name or a table name with a WHERE clause already on it.
    func count(_ from: String) throws -> Int {
        try db.queryOne("SELECT count(*) FROM \(from)") { $0.int(0) } ?? -1
    }

    func uuids(_ table: String) throws -> [String] {
        try db.query("SELECT uuid FROM \(table) ORDER BY id") { $0.text(0) }
    }
}

@Suite struct SyncStateTests {
    @Test func startsWithADeviceIdAndNothingPulled() throws {
        let h = try Harness()
        let state = try h.repo.syncState()
        #expect(state.deviceID.count == 36)
        #expect(state.userID == nil)
        #expect(state.cursor == 0)
        #expect(state.lastSyncedAt == nil)
    }

    @Test func claimingRecordsTheUser() throws {
        let h = try Harness()
        try h.repo.claimLocalData(forUserID: "user-a")
        #expect(try h.repo.syncState().userID == "user-a")
        // Re-claiming by the same user is a no-op, not an error — signing in twice
        // on one machine is ordinary.
        try h.repo.claimLocalData(forUserID: "user-a")
        #expect(try h.repo.syncState().userID == "user-a")
    }

    /// Two people's hours in one file cannot be told apart afterwards, so the merge
    /// must be refused at the door rather than regretted later. Going through anyway
    /// is `transferLocalData`, and it is a different, deliberate call.
    @Test func refusesASecondUserOnTheSameStore() throws {
        let h = try Harness()
        try h.repo.claimLocalData(forUserID: "user-a")
        #expect(throws: MutationError.self) {
            try h.repo.claimLocalData(forUserID: "user-b")
        }
        #expect(try h.repo.syncState().userID == "user-a")
    }

    /// Only when there is something to displace: an unclaimed store, or the same
    /// user signing in again, has no question to ask.
    @Test func namesTheOwnerOnlyWhenOneWouldBeDisplaced() throws {
        let h = try Harness()
        #expect(try h.repo.ownerToDisplace(signingInAs: "user-a") == nil)
        try h.repo.claimLocalData(forUserID: "user-a")
        #expect(try h.repo.ownerToDisplace(signingInAs: "user-a") == nil)
        #expect(try h.repo.ownerToDisplace(signingInAs: "user-b") == "user-a")
    }

    /// The whole point of the transfer: the hours stay on the machine.
    @Test func transferKeepsEveryRowAndRestampsTheStore() throws {
        let h = try Harness()
        try h.seed(date: "2026-08-05", startedAt: 1_000, endedAt: 2_000)
        try h.seed(date: "2026-08-06", startedAt: 3_000, endedAt: 4_000)
        try h.repo.claimLocalData(forUserID: "user-a")

        try h.repo.transferLocalData(toUserID: "user-b")

        #expect(try h.repo.syncState().userID == "user-b")
        #expect(try h.count("days") == 2)
        #expect(try h.count("segments") == 2)
    }

    /// A uuid is the row's identity on the server, where the primary key is global
    /// rather than per-account. Carrying one across would push this machine's copy
    /// on top of the previous owner's row — overwriting their history — while the
    /// new owner's pull, filtered by user_id, never returns it.
    @Test func transferReissuesEveryRowIdentity() throws {
        let h = try Harness()
        try h.seed(date: "2026-08-05", startedAt: 1_000, endedAt: 2_000)
        try h.repo.claimLocalData(forUserID: "user-a")
        let before = try h.uuids("days") + h.uuids("segments")

        try h.repo.transferLocalData(toUserID: "user-b")

        let after = try h.uuids("days") + h.uuids("segments")
        #expect(after.count == before.count)
        #expect(Set(after).isDisjoint(with: Set(before)))
        // Still UUIDv7, so the re-identified rows keep sorting into the order they
        // were lived in rather than arriving at the server shuffled.
        #expect(after.allSatisfy { $0.count == 36 && Array($0)[14] == "7" })
    }

    /// Everything has to go up again: under the new account these are rows the
    /// server has never seen, whatever the old account's sync had acknowledged.
    @Test func transferQueuesEverythingForTheNewAccount() throws {
        let h = try Harness()
        try h.seed(date: "2026-08-05", startedAt: 1_000, endedAt: 2_000)
        try h.repo.claimLocalData(forUserID: "user-a")
        // As though the previous owner had synced it all.
        try h.db.run("UPDATE days     SET dirty = 0, server_seq = 42")
        try h.db.run("UPDATE segments SET dirty = 0, server_seq = 43")
        try h.repo.advanceCursor(to: 99, at: 5_000)

        try h.repo.transferLocalData(toUserID: "user-b")

        #expect(try h.dirtyCount("days") == 1)
        #expect(try h.dirtyCount("segments") == 1)
        #expect(try h.count("days WHERE server_seq IS NOT NULL") == 0)
        #expect(try h.count("segments WHERE server_seq IS NOT NULL") == 0)
        // The cursor counted the previous owner's place in the server's sequence.
        // Keeping it would skip everything already in the new account's history.
        #expect(try h.repo.syncState().cursor == 0)
        #expect(try h.repo.syncState().lastSyncedAt == nil)
    }

    /// A tombstone says "the row I sent you is gone". The new account was never sent
    /// it, so pushing one would be a delete for a row that does not exist there.
    @Test func transferDoesNotPushTheOldAccountsDeletions() throws {
        let h = try Harness()
        try h.seed(date: "2026-08-05", startedAt: 1_000, endedAt: 2_000)
        try h.seed(date: "2026-08-06", startedAt: 3_000, endedAt: 4_000)
        try h.repo.claimLocalData(forUserID: "user-a")
        try h.db.run("UPDATE days SET deleted_at = 9_000 WHERE date = '2026-08-06'")

        try h.repo.transferLocalData(toUserID: "user-b")

        #expect(try h.dirtyCount("days") == 1)
        #expect(try h.count("days WHERE deleted_at IS NOT NULL AND dirty = 1") == 0)
    }

    /// A response that arrives late must not rewind a cursor that has moved on;
    /// rewinding re-delivers rows already applied.
    @Test func theCursorNeverMovesBackwards() throws {
        let h = try Harness()
        try h.repo.advanceCursor(to: 100, at: 1_000)
        try h.repo.advanceCursor(to: 40, at: 2_000)
        #expect(try h.repo.syncState().cursor == 100)
        try h.repo.advanceCursor(to: 150, at: 3_000)
        #expect(try h.repo.syncState().cursor == 150)
    }
}

@Suite struct PendingPushTests {
    @Test func offersEveryDirtyRow() throws {
        let h = try Harness()
        try h.seed(date: "2026-08-06", startedAt: 1_786_000_000_000, endedAt: 1_786_003_600_000)

        let pending = try h.repo.pendingPush()
        #expect(pending.days.count == 1)
        #expect(pending.segments.count == 1)
        #expect(pending.segments[0].dayDate.description == "2026-08-06")
        #expect(pending.segments[0].type == .work)
        #expect(!pending.isEmpty)
    }

    @Test func offersNothingOnceEverythingIsAcknowledged() throws {
        let h = try Harness()
        try h.seed(date: "2026-08-06", startedAt: 1_786_000_000_000, endedAt: 1_786_003_600_000)
        let pending = try h.repo.pendingPush()

        try h.repo.markPushed(pending.days.map { ($0.uuid, $0.updatedAt) }, table: .days)
        try h.repo.markPushed(pending.segments.map { ($0.uuid, $0.updatedAt) }, table: .segments)

        #expect(try h.repo.pendingPush().isEmpty)
    }

    /// The user edits a row while the push is in flight. Acknowledging it blindly
    /// would clear `dirty` on an edit the server never saw, losing it silently.
    @Test func aRowEditedMidFlightStaysDirty() throws {
        let h = try Harness()
        try h.seed(date: "2026-08-06", startedAt: 1_786_000_000_000, endedAt: 1_786_003_600_000)
        let sent = try h.repo.pendingPush()

        // The edit lands after the request left, before the response came back.
        try h.db.run("UPDATE segments SET note = 'edited', updated_at = 1786009999999")

        try h.repo.markPushed(sent.segments.map { ($0.uuid, $0.updatedAt) }, table: .segments)

        #expect(try h.dirtyCount("segments") == 1, "the newer edit must still be pending")
    }
}

@Suite struct ApplyRemoteTests {
    private func remoteSegment(
        uuid: String = UUID().uuidString.lowercased(),
        date: String = "2026-08-07",
        startedAt: EpochMs = 1_786_100_000_000,
        updatedAt: EpochMs = 1_786_100_000_000,
        deletedAt: EpochMs? = nil
    ) -> SyncSegment {
        SyncSegment(
            uuid: uuid, dayDate: DateKey(date)!, type: .work,
            startedAt: startedAt, endedAt: startedAt + 3_600_000,
            createdAt: startedAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }

    /// Rows that came from the server must not be pushed straight back at it.
    @Test func remoteRowsArriveClean() throws {
        let h = try Harness()
        try h.repo.applyRemote(days: [], segments: [remoteSegment()], serverSeq: 42)

        #expect(try h.dirtyCount("segments") == 0)
        let seq = try h.db.queryOne("SELECT server_seq FROM segments") { $0.optionalInt64(0) }
        #expect(seq == 42)
    }

    /// Sync delivers commit order, not dependency order, so a segment can arrive
    /// before the day it belongs to. Dropping it would strand the client.
    @Test func createsTheDayASegmentNeedsIfItIsMissing() throws {
        let h = try Harness()
        try h.repo.applyRemote(days: [], segments: [remoteSegment(date: "2026-09-01")], serverSeq: 7)

        let dayCount = try h.db.queryOne(
            "SELECT count(*) FROM days WHERE date = '2026-09-01'"
        ) { $0.int(0) }
        #expect(dayCount == 1)
        // And that stand-in day must not be pushed back to the server.
        #expect(try h.dirtyCount("days") == 0)
    }

    @Test func anOlderRemoteRowDoesNotOverwriteANewerLocalEdit() throws {
        let h = try Harness()
        let id = UUID().uuidString.lowercased()
        try h.repo.applyRemote(days: [], segments: [remoteSegment(uuid: id, updatedAt: 5_000)], serverSeq: 1)

        // The user edits locally, then a stale copy of the row arrives.
        try h.db.run("UPDATE segments SET note = 'mine', updated_at = 9_000 WHERE uuid = ?", [.text(id)])
        try h.repo.applyRemote(
            days: [], segments: [remoteSegment(uuid: id, updatedAt: 5_000)], serverSeq: 2
        )

        let note = try h.db.queryOne("SELECT note FROM segments WHERE uuid = ?", [.text(id)]) {
            $0.optionalText(0)
        }
        #expect(note == "mine", "the newer local edit must survive")
    }

    @Test func aNewerRemoteRowWins() throws {
        let h = try Harness()
        let id = UUID().uuidString.lowercased()
        try h.repo.applyRemote(days: [], segments: [remoteSegment(uuid: id, updatedAt: 5_000)], serverSeq: 1)
        try h.db.run("UPDATE segments SET note = 'mine', updated_at = 6_000 WHERE uuid = ?", [.text(id)])

        var newer = remoteSegment(uuid: id, updatedAt: 9_000)
        newer.note = "theirs"
        try h.repo.applyRemote(days: [], segments: [newer], serverSeq: 3)

        let note = try h.db.queryOne("SELECT note FROM segments WHERE uuid = ?", [.text(id)]) {
            $0.optionalText(0)
        }
        #expect(note == "theirs")
    }

    /// A tombstone is applied like any other update, so a delete made elsewhere
    /// reaches this device instead of the row lingering.
    @Test func aRemoteTombstoneIsRecorded() throws {
        let h = try Harness()
        let id = UUID().uuidString.lowercased()
        try h.repo.applyRemote(days: [], segments: [remoteSegment(uuid: id, updatedAt: 1_000)], serverSeq: 1)
        try h.repo.applyRemote(
            days: [], segments: [remoteSegment(uuid: id, updatedAt: 2_000, deletedAt: 2_000)],
            serverSeq: 2
        )

        let deletedAt = try h.db.queryOne(
            "SELECT deleted_at FROM segments WHERE uuid = ?", [.text(id)]
        ) { $0.optionalInt64(0) }
        #expect(deletedAt == 2_000)
    }

    @Test func applyingTheSameRowTwiceChangesNothing() throws {
        let h = try Harness()
        let segment = remoteSegment()
        try h.repo.applyRemote(days: [], segments: [segment], serverSeq: 1)
        try h.repo.applyRemote(days: [], segments: [segment], serverSeq: 1)

        let count = try h.db.queryOne("SELECT count(*) FROM segments") { $0.int(0) }
        #expect(count == 1)
    }
}
