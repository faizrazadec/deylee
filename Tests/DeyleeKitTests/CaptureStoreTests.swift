import Foundation
import Testing

@testable import DeyleeKit

/// Screen captures in the local store.
///
/// The behaviour worth pinning is not "a row can be written" — it is what happens when
/// somebody deletes one, and whether the image is really gone from the file rather than
/// merely hidden from a query.
@Suite struct Captures {
    private static func store() throws -> (Database, Repository) {
        let db = try Database(path: ":memory:")
        try runMigrations(db)
        return (db, Repository(db: db))
    }

    private static let day = DateKey("2026-08-10")!
    private static func image(_ marker: String) -> Data {
        // Recognisable bytes, so a test can look for them in the raw file.
        Data("PNGDATA-\(marker)-PNGDATA".utf8)
    }

    @Test func recordsAndReadsBackACapture() throws {
        let (_, repo) = try Self.store()
        let id = try repo.insertCapture(
            dayDate: Self.day, segmentID: nil, capturedAt: 1_000, width: 2880, height: 1800,
            bytes: Self.image("one"), now: 1_000
        )
        let capture = try #require(try repo.capture(id: id))
        #expect(capture.bytes == Self.image("one"))
        #expect(capture.width == 2880)
        #expect(capture.dayDate == Self.day)
        // Sync identity is minted by the insert, not left for later.
        #expect(!capture.uuid.isEmpty)
    }

    @Test func listingADayDoesNotCarryTheImages() throws {
        let (_, repo) = try Self.store()
        for i in 0..<3 {
            try repo.insertCapture(
                dayDate: Self.day, segmentID: nil, capturedAt: EpochMs(1_000 + i * 60_000),
                width: 100, height: 100, bytes: Self.image("\(i)"), now: 1_000
            )
        }
        let summaries = try repo.captureSummaries(on: Self.day)
        #expect(summaries.count == 3)
        // Newest first, so a list opens on what just happened.
        #expect(summaries[0].capturedAt > summaries[2].capturedAt)
        #expect(summaries[0].byteCount == Self.image("2").count)
    }

    /// The property that matters most: deleting a capture releases the picture at once
    /// rather than keeping it until a tombstone has synced. A person deleting a
    /// screenshot means the image, not the bookkeeping.
    @Test func deletingReleasesTheImageImmediately() throws {
        let (db, repo) = try Self.store()
        let id = try repo.insertCapture(
            dayDate: Self.day, segmentID: nil, capturedAt: 1_000, width: 10, height: 10,
            bytes: Self.image("secret"), now: 1_000
        )
        #expect(try repo.deleteCapture(id, now: 2_000))

        // Gone from every read path...
        #expect(try repo.capture(id: id) == nil)
        #expect(try repo.captureSummaries(on: Self.day).isEmpty)

        // ...and the bytes themselves are cleared, while the row survives to carry the
        // deletion to other devices.
        let row = try #require(
            try db.queryOne(
                "SELECT length(bytes), deleted_at IS NOT NULL, dirty FROM captures WHERE id = ?",
                [.integer(id)]
            ) { ($0.int(0), $0.int(1), $0.int(2)) }
        )
        #expect(row.0 == 0, "the image should be released, not retained behind a tombstone")
        #expect(row.1 == 1, "the tombstone must survive so the delete can travel")
        #expect(row.2 == 1, "and be queued for push")
    }

    @Test func deleteAllClearsEveryLiveCapture() throws {
        let (_, repo) = try Self.store()
        for i in 0..<5 {
            try repo.insertCapture(
                dayDate: Self.day, segmentID: nil, capturedAt: EpochMs(1_000 + i),
                width: 10, height: 10, bytes: Self.image("\(i)"), now: 1_000
            )
        }
        #expect(try repo.deleteAllCaptures(now: 2_000) == 5)
        #expect(try repo.captureFootprint().count == 0)
        #expect(try repo.captureFootprint().bytes == 0)
        // Idempotent: a second press has nothing left to do rather than failing.
        #expect(try repo.deleteAllCaptures(now: 3_000) == 0)
    }

    @Test func retentionSweepsOnlyWhatIsOlderThanTheWindow() throws {
        let (_, repo) = try Self.store()
        let now: EpochMs = 30 * 86_400_000
        let old = now - 20 * 86_400_000
        let recent = now - 2 * 86_400_000
        try repo.insertCapture(
            dayDate: Self.day, segmentID: nil, capturedAt: old, width: 1, height: 1,
            bytes: Self.image("old"), now: old
        )
        try repo.insertCapture(
            dayDate: Self.day, segmentID: nil, capturedAt: recent, width: 1, height: 1,
            bytes: Self.image("recent"), now: recent
        )

        #expect(try repo.sweepCaptures(olderThan: 14, now: now) == 1)
        let left = try repo.captureSummaries(on: Self.day)
        #expect(left.count == 1)
        #expect(left[0].capturedAt == recent)
    }

    /// Captures live in the SQLCipher database rather than as files beside it, which is
    /// what makes them encrypted at rest for free. This asserts the consequence on a
    /// real file: the image bytes must not be readable by anything that opens the store
    /// without the key.
    @Test func capturedImagesAreNotReadableInTheFileWithoutTheKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "deylee-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "s.sqlite").path
        let key = [UInt8](repeating: 7, count: 32)

        do {
            let db = try openDatabase(at: path, key: key)
            try runMigrations(db)
            try Repository(db: db).insertCapture(
                dayDate: Self.day, segmentID: nil, capturedAt: 1_000, width: 1, height: 1,
                bytes: Self.image("verysecret"), now: 1_000
            )
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }

        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(raw.range(of: Data("verysecret".utf8)) == nil,
                "capture bytes must not be recoverable from the encrypted file")
    }
}
