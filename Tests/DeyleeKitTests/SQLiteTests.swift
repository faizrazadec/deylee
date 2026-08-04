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
