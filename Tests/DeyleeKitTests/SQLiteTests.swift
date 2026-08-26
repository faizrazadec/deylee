import Foundation
import Testing
@testable import DeyleeKit

private func openScratch() throws -> Database {
    let db = try Database(path: ":memory:")
    try db.execute("""
        CREATE TABLE items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            note TEXT
        );
        """)
    return db
}

@Suite struct SQLiteWrapper {
    @Test func insertsAndQueriesTypedValues() throws {
        let db = try openScratch()
        try db.run(
            "INSERT INTO items (name, started_at, note) VALUES (?, ?, ?)",
            [.text("focus"), .integer(1_754_300_000_000), .null]
        )
        #expect(db.lastInsertRowID == 1)

        let rows = try db.query("SELECT name, started_at, note FROM items") { row in
            (row.text(0), row.int64(1), row.optionalText(2))
        }
        #expect(rows.count == 1)
        #expect(rows[0].0 == "focus")
        #expect(rows[0].1 == 1_754_300_000_000)
        #expect(rows[0].2 == nil)
    }

    @Test func bindsParametersPositionally() throws {
        let db = try openScratch()
        for (name, at) in [("a", Int64(1)), ("b", 2), ("c", 3)] {
            try db.run("INSERT INTO items (name, started_at) VALUES (?, ?)", [.text(name), .integer(at)])
        }
        let names = try db.query(
            "SELECT name FROM items WHERE started_at >= ? ORDER BY started_at",
            [.integer(2)]
        ) { $0.text(0) }
        #expect(names == ["b", "c"])
    }

    @Test func reportsChanges() throws {
        let db = try openScratch()
        try db.run("INSERT INTO items (name, started_at) VALUES ('x', 1)")
        try db.run("INSERT INTO items (name, started_at) VALUES ('y', 2)")
        try db.run("UPDATE items SET started_at = 0")
        #expect(db.changes == 2)
    }

    @Test func rollsBackAThrowingTransaction() throws {
        let db = try openScratch()
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.run("INSERT INTO items (name, started_at) VALUES ('gone', 1)")
                throw Boom()
            }
        }
        let count = try db.queryOne("SELECT COUNT(*) FROM items") { $0.int(0) }
        #expect(count == 0)
    }

    @Test func commitsASuccessfulTransaction() throws {
        let db = try openScratch()
        let id: Int64 = try db.transaction {
            try db.run("INSERT INTO items (name, started_at) VALUES ('kept', 1)")
            return db.lastInsertRowID
        }
        #expect(id == 1)
        let count = try db.queryOne("SELECT COUNT(*) FROM items") { $0.int(0) }
        #expect(count == 1)
    }

    @Test func surfacesSQLErrorsAsFailures() throws {
        let db = try openScratch()
        #expect(throws: Database.Failure.self) {
            try db.run("INSERT INTO missing_table (name) VALUES ('x')")
        }
        #expect(throws: Database.Failure.self) {
            try db.execute("NOT EVEN SQL")
        }
    }

    @Test func enforcesConstraints() throws {
        let db = try openScratch()
        #expect(throws: Database.Failure.self) {
            try db.run("INSERT INTO items (name, started_at) VALUES (NULL, 1)")
        }
    }
}

/// The single Keychain item that replaced two.
///
/// Merging the store key and the session invites one specific catastrophe — deleting
/// the item to sign out, taking the encryption key with it — so the sign-out path is
/// pinned here rather than left to a comment.
@Suite struct VaultContentsShape {
    private let key = Data(repeating: 7, count: 32)

    @Test func survivesTheRoundTrip() throws {
        let vault = VaultContents(storeKey: key, session: Data("session".utf8))
        let restored = try #require(VaultContents.decoded(try vault.encoded()))
        #expect(restored == vault)
        #expect(restored.storeKey == key)
    }

    @Test func signingOutKeepsTheKey() throws {
        let vault = VaultContents(storeKey: key, session: Data("session".utf8))
        let out = vault.withoutSession()
        #expect(out.session == nil)
        #expect(out.storeKey == key, "signing out must never touch the encryption key")

        // And it survives being written and read as a signed-out vault.
        let restored = try #require(VaultContents.decoded(try out.encoded()))
        #expect(restored.storeKey == key)
        #expect(restored.session == nil)
    }

    /// Nobody signed in is ordinary, not an error.
    @Test func aVaultWithNoSessionIsValid() throws {
        let vault = VaultContents(storeKey: key)
        #expect(VaultContents.decoded(try vault.encoded())?.session == nil)
    }

    /// Unreadable must be nil, never a partial value: the caller falls back to the
    /// legacy items, and a half-read vault would let it conclude the key was lost.
    @Test func refusesAnythingThatIsNotAWholeVault() {
        #expect(VaultContents.decoded(Data("not json".utf8)) == nil)
        #expect(VaultContents.decoded(Data()) == nil)
        // Right shape, wrong key length — a 16-byte key would open nothing.
        let short = try! VaultContents(storeKey: Data(repeating: 1, count: 16)).encoded()
        #expect(VaultContents.decoded(short) == nil, "a key of the wrong size is not a key")
    }
}
