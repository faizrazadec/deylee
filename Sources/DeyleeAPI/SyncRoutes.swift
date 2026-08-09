import Foundation
import Hummingbird
import Logging
import PostgresNIO

// MARK: - Wire types

/// One row, in the shape the protocol moves it. Fields not belonging to the table
/// named alongside it are absent; `days` has `date` and `targetMinutes`, `segments`
/// has `dayDate`, `type`, `startedAt` and `note`, and both use `endedAt`.
struct SyncRow: Codable, Sendable {
    /// A string, not a `UUID`, and lower-cased on the way out.
    ///
    /// Foundation renders `UUID.uuidString` in upper case, while Postgres and the
    /// clients' SQLite stores both use lower case. Since a client upserts by this
    /// value into a case-SENSITIVE text index, echoing it back in the wrong case
    /// would insert a duplicate of every row it already held.
    let id: String
    var dayDate: String?
    var type: String?
    var startedAt: Int64?
    var endedAt: Int64?
    var note: String?
    var date: String?
    var targetMinutes: Int?
    var createdAt: Int64?
    var updatedAt: Int64
    var deletedAt: Int64?
    /// Server-assigned, present only on rows coming back out.
    var seq: Int64?
}

struct SyncChange: Codable, Sendable {
    let table: String
    let op: String
    let row: SyncRow
}

struct SyncRequest: Decodable {
    let protocolVersion: Int
    let deviceId: UUID?
    let cursor: Int64
    let changes: [SyncChange]
}

struct ChangeResult: Codable, ResponseEncodable, Sendable {
    let id: String
    let status: String
    var code: String?
    var message: String?
}

struct SyncResponse: Codable, ResponseEncodable, Sendable {
    let protocolVersion: Int
    let cursor: Int64
    let serverTime: Int64
    let hasMore: Bool
    let results: [ChangeResult]
    let changes: [SyncChange]
}

// MARK: - Routes

struct SyncController: Sendable {
    let store: Store
    let tokens: TokenService
    let logger: Logger

    /// Rows returned per response. A first sync of years of history is many round
    /// trips by design; one request carrying all of it would time out.
    static let pageSize = 500
    /// Changes accepted per push, matching the 413 in the protocol.
    static let maxChangesPerPush = 500
    static let protocolVersion = 1

    func addRoutes(to router: Router<BasicRequestContext>) {
        router.post("/v1/sync", use: sync)
    }

    @Sendable
    func sync(_ request: Request, context: BasicRequestContext) async throws -> SyncResponse {
        let userID = try await authenticate(request)
        let body = try await request.decode(as: SyncRequest.self, context: context)

        guard body.protocolVersion == Self.protocolVersion else {
            throw HTTPError(.badRequest, message: "Unsupported protocolVersion \(body.protocolVersion).")
        }
        guard body.changes.count <= Self.maxChangesPerPush else {
            throw HTTPError(.contentTooLarge, message: "At most \(Self.maxChangesPerPush) changes per push.")
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // One transaction for push and pull together, holding the per-user advisory
        // lock. That lock is what makes the cursor trustworthy: sequence values are
        // handed out at write time but transactions commit out of order, so without
        // serialising a user's writes a pull can step past a row that has not
        // committed yet and never come back for it.
        return try await store.withUser(userID, lockForWrite: true) { connection in
            var results: [ChangeResult] = []
            for (index, change) in body.changes.enumerated() {
                results.append(await apply(change, at: index, userID: userID, on: connection))
            }

            var pulled = try await self.pull(after: body.cursor, userID: userID, on: connection)
            let hasMore = pulled.count > Self.pageSize
            if hasMore { pulled = Array(pulled.prefix(Self.pageSize)) }

            return SyncResponse(
                protocolVersion: Self.protocolVersion,
                cursor: pulled.last?.row.seq ?? body.cursor,
                serverTime: now,
                hasMore: hasMore,
                results: results,
                changes: pulled
            )
        }
    }

    // MARK: Authentication

    private func authenticate(_ request: Request) async throws -> UUID {
        guard let header = request.headers[.authorization],
              header.hasPrefix("Bearer ")
        else {
            throw HTTPError(.unauthorized, message: "A bearer token is required.")
        }
        let raw = String(header.dropFirst("Bearer ".count))
        guard let payload = try? await tokens.verifyAccessToken(raw),
              let id = UUID(uuidString: payload.sub.value)
        else {
            throw HTTPError(.unauthorized, message: "That access token is not valid.")
        }
        return id
    }

    // MARK: Push

    /// Apply one change in its own savepoint.
    ///
    /// A rejection must not take the rest of the batch down with it. A client
    /// holding one corrupt row would otherwise be unable to sync anything, ever —
    /// the failure would be permanent and total rather than local to the row.
    /// The name comes from the row's position in the batch, which is unique by
    /// construction and cannot trap.
    ///
    /// It used to be `abs(row.id.hashValue)`, which was wrong twice. `abs(Int.min)` is
    /// a runtime trap in Swift, and a trap here takes the process down with every
    /// in-flight sync on it, not just the request that caused it — the house rule that
    /// arithmetic reaching disk saturates rather than traps exists for exactly this.
    /// And two ids colliding inside one batch produced the same name, so a release
    /// freed the earlier savepoint and a later rollback unwound a row that had already
    /// been applied. Both are long odds; one is a crash and the other is silent
    /// corruption, and an index costs nothing.
    private func apply(
        _ change: SyncChange, at index: Int, userID: UUID, on connection: PostgresConnection
    ) async -> ChangeResult {
        let name = "sp_\(index)"
        do {
            _ = try await connection.query(PostgresQuery(unsafeSQL: "SAVEPOINT \(name)"), logger: logger)
            switch (change.table, change.op) {
            case ("segments", "upsert"): try await upsertSegment(change.row, userID: userID, on: connection)
            case ("segments", "delete"): try await tombstone("segments", change.row, userID: userID, on: connection)
            case ("days", "upsert"): try await upsertDay(change.row, userID: userID, on: connection)
            case ("days", "delete"): try await tombstone("days", change.row, userID: userID, on: connection)
            default:
                throw HTTPError(.badRequest, message: "Unknown \(change.table)/\(change.op).")
            }
            _ = try await connection.query(PostgresQuery(unsafeSQL: "RELEASE SAVEPOINT \(name)"), logger: logger)
            return ChangeResult(id: change.row.id, status: "applied")
        } catch {
            _ = try? await connection.query(
                PostgresQuery(unsafeSQL: "ROLLBACK TO SAVEPOINT \(name)"), logger: logger
            )
            let (code, message) = Self.classify(error)
            return ChangeResult(
                id: change.row.id, status: "rejected", code: code, message: message
            )
        }
    }

    /// Map a database refusal onto the protocol's vocabulary.
    ///
    /// These mirror MutationErrorCode in DeyleeKit so the Mac app can surface a
    /// server rejection through the path it already uses for a local one.
    static func classify(_ error: any Error) -> (String, String) {
        if let psql = error as? PSQLError, let sqlState = psql.serverInfo?[.sqlState] {
            switch sqlState {
            case "23P01":
                // The exclusion constraint. Two open segments both run to infinity,
                // so this is also what "already running elsewhere" looks like.
                return ("overlap", "That time overlaps a segment already recorded.")
            case "23514":
                // The integrity bounds raise through this class on purpose — it is
                // already a per-row rejection, and never class 28 (see the
                // sign_in_error_code migration for what that class costs).
                let message = psql.serverInfo?[.message] ?? ""
                if message == "in-the-future" {
                    return ("invalid-shape", "That time has not happened yet.")
                }
                if message.contains("segments_duration_sane") {
                    return ("invalid-shape", "A segment cannot be longer than sixteen hours.")
                }
                return ("invalid-shape", "A field failed validation.")
            case "23503":
                return ("invalid-shape", "That row refers to something that does not exist.")
            case "23505":
                return ("stale", "A row with that identity already exists.")
            default:
                return ("invalid-shape", psql.serverInfo?[.message] ?? sqlState)
            }
        }
        if let http = error as? HTTPError { return ("invalid-shape", http.body ?? "Rejected.") }
        return ("invalid-shape", String(describing: error))
    }

    // Last-write-wins, decided in the WHERE clause rather than by reading the row
    // first: reading then writing would race with the other device's push even
    // inside a transaction, and the comparison belongs where the write happens.
    //
    // Strictly greater, so an identical timestamp is a no-op. Replaying a push —
    // which the protocol requires to be safe — therefore changes nothing.

    private func upsertSegment(
        _ row: SyncRow, userID: UUID, on connection: PostgresConnection
    ) async throws {
        guard let dayDate = row.dayDate, let type = row.type, let startedAt = row.startedAt else {
            throw HTTPError(.badRequest, message: "A segment needs dayDate, type and startedAt.")
        }
        guard let rowID = UUID(uuidString: row.id) else {
            throw HTTPError(.badRequest, message: "That id is not a UUID.")
        }
        _ = try await connection.query(
            """
            INSERT INTO public.segments
                (id, user_id, day_date, type, started_at, ended_at, note, created_at, updated_at)
            VALUES (\(rowID), \(userID), \(dayDate), \(type), \(startedAt), \(row.endedAt),
                    \(row.note), \(row.createdAt ?? row.updatedAt), \(row.updatedAt))
            ON CONFLICT (id) DO UPDATE SET
                day_date   = EXCLUDED.day_date,
                type       = EXCLUDED.type,
                started_at = EXCLUDED.started_at,
                ended_at   = EXCLUDED.ended_at,
                note       = EXCLUDED.note,
                updated_at = EXCLUDED.updated_at
            WHERE EXCLUDED.updated_at > segments.updated_at
            """,
            logger: logger
        )
    }

    private func upsertDay(
        _ row: SyncRow, userID: UUID, on connection: PostgresConnection
    ) async throws {
        guard let date = row.date, let target = row.targetMinutes else {
            throw HTTPError(.badRequest, message: "A day needs date and targetMinutes.")
        }
        guard let rowID = UUID(uuidString: row.id) else {
            throw HTTPError(.badRequest, message: "That id is not a UUID.")
        }
        _ = try await connection.query(
            """
            INSERT INTO public.days
                (id, user_id, date, target_minutes, ended_at, created_at, updated_at)
            VALUES (\(rowID), \(userID), \(date), \(target), \(row.endedAt),
                    \(row.createdAt ?? row.updatedAt), \(row.updatedAt))
            ON CONFLICT (id) DO UPDATE SET
                date           = EXCLUDED.date,
                target_minutes = EXCLUDED.target_minutes,
                ended_at       = EXCLUDED.ended_at,
                updated_at     = EXCLUDED.updated_at
            WHERE EXCLUDED.updated_at > days.updated_at
            """,
            logger: logger
        )
    }

    /// A tombstone wins a tie, hence `>=`. Deletion is the conservative outcome:
    /// the row is still there and can be restored, whereas resurrecting time
    /// somebody deleted shows them hours they believed were gone.
    private func tombstone(
        _ table: String, _ row: SyncRow, userID: UUID, on connection: PostgresConnection
    ) async throws {
        guard let rowID = UUID(uuidString: row.id) else {
            throw HTTPError(.badRequest, message: "That id is not a UUID.")
        }
        let query: PostgresQuery = table == "segments"
            ? """
              UPDATE public.segments SET deleted_at = \(row.updatedAt), updated_at = \(row.updatedAt)
              WHERE id = \(rowID) AND user_id = \(userID)
                AND deleted_at IS NULL AND \(row.updatedAt) >= updated_at
              """
            : """
              UPDATE public.days SET deleted_at = \(row.updatedAt), updated_at = \(row.updatedAt)
              WHERE id = \(rowID) AND user_id = \(userID)
                AND deleted_at IS NULL AND \(row.updatedAt) >= updated_at
              """
        _ = try await connection.query(query, logger: logger)
    }

    // MARK: Pull

    /// Everything past the cursor, from both tables, in commit order.
    ///
    /// One extra row is fetched beyond the page so `hasMore` is known without a
    /// second count query.
    private func pull(
        after cursor: Int64, userID: UUID, on connection: PostgresConnection
    ) async throws -> [SyncChange] {
        let limit = Self.pageSize + 1
        var out: [SyncChange] = []

        let segments = try await connection.query(
            """
            SELECT id, day_date, type, started_at, ended_at, note,
                   created_at, updated_at, deleted_at, seq
            FROM public.segments WHERE user_id = \(userID) AND seq > \(cursor)
             ORDER BY seq LIMIT \(limit)
            """,
            logger: logger
        )
        for try await (id, dayDate, type, startedAt, endedAt, note, createdAt, updatedAt, deletedAt, seq)
            in segments.decode(
                (UUID, String, String, Int64, Int64?, String?, Int64, Int64, Int64?, Int64).self
            )
        {
            out.append(SyncChange(
                table: "segments",
                op: deletedAt == nil ? "upsert" : "delete",
                row: SyncRow(
                    id: id.uuidString.lowercased(), dayDate: dayDate, type: type,
                    startedAt: startedAt, endedAt: endedAt,
                    note: note, createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt,
                    seq: seq
                )
            ))
        }

        let days = try await connection.query(
            """
            SELECT id, date, target_minutes, ended_at, created_at, updated_at, deleted_at, seq
            FROM public.days WHERE user_id = \(userID) AND seq > \(cursor)
             ORDER BY seq LIMIT \(limit)
            """,
            logger: logger
        )
        for try await (id, date, target, endedAt, createdAt, updatedAt, deletedAt, seq)
            in days.decode((UUID, String, Int, Int64?, Int64, Int64, Int64?, Int64).self)
        {
            out.append(SyncChange(
                table: "days",
                op: deletedAt == nil ? "upsert" : "delete",
                row: SyncRow(
                    id: id.uuidString.lowercased(), endedAt: endedAt, date: date, targetMinutes: target,
                    createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt, seq: seq
                )
            ))
        }

        // Interleaved by seq, because the two tables share one sequence and a
        // client applying them out of order would see a segment before its day.
        return out.sorted { ($0.row.seq ?? 0) < ($1.row.seq ?? 0) }
    }
}
