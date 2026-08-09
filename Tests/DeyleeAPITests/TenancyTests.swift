import Foundation
import Logging
import PostgresNIO
import Testing

@testable import DeyleeAPI

/// One customer cannot see another's hours.
///
/// The property the whole product rests on, and until now the only one with nothing
/// behind it. It cannot be asserted without a database: row-level security is the
/// layer under test, and a mock would only prove the mock.
///
/// Set `DEYLEE_TEST_DB_URL` to run these. `./scripts/dev-db.sh` builds exactly the
/// right thing — the production schema in a throwaway container — and prints the URL:
///
///     DEYLEE_TEST_DB_URL='postgresql://deylee_api_user:devpassword@127.0.0.1:5433/postgres' \
///       ./scripts/test-server.sh
///
/// Skipped when it is unset, so the suite still runs with no Docker. That is a real
/// gap and not a comfortable one: unset the variable and the guarantee goes untested
/// exactly as it was before. Point CI at a container and it stops being optional.
///
/// **The URL must be the restricted login, not the owner.** Connecting as `postgres`
/// makes every one of these pass while proving nothing, because policies do not apply
/// to a superuser — which is the misconfiguration the boot check exists to refuse.
/// `roleCannotBypassPolicies` fails loudly rather than letting the rest pass hollow.
private let testDatabaseURL = ProcessInfo.processInfo.environment["DEYLEE_TEST_DB_URL"]

@Suite(.enabled(if: testDatabaseURL != nil, "set DEYLEE_TEST_DB_URL to run"))
struct Tenancy {
    private func makeStore() throws -> Store {
        try Store(
            url: testDatabaseURL!, tls: false, caCertificatePath: nil,
            logger: Logger(label: "tenancy-test")
        )
    }

    /// Runs `body` against a live pool, then shuts it down.
    private func withStore(_ body: @escaping @Sendable (Store) async throws -> Void) async throws {
        let store = try makeStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await store.client.run() }
            do {
                try await body(store)
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    /// Two accounts, through the same SECURITY DEFINER function the Google route
    /// calls. The restricted role cannot write `app_users` directly — that is what
    /// makes it restricted — so seeding any other way would need a privileged
    /// connection and would prove less.
    ///
    /// Fixed Google subjects, so a run reuses the same two accounts instead of leaving
    /// a new pair behind every time.
    private func seedTwoUsers(_ store: Store) async throws -> (UUID, UUID) {
        var ids: [UUID] = []
        for sub in ["tenancy-test-a", "tenancy-test-b"] {
            let id = try await store.withoutTenant { connection -> UUID in
                let rows = try await connection.query(
                    """
                    SELECT id FROM public.auth_sign_in_with_google(
                        \(sub), \(sub + "@tenancy.invalid"), true, 'Probe', 'UTC')
                    """,
                    logger: Logger(label: "seed")
                )
                for try await id in rows.decode(UUID.self) { return id }
                throw StoreError.malformedURL
            }
            ids.append(id)
        }
        try await removeDays(store, ids)
        return (ids[0], ids[1])
    }

    /// Tombstoned rather than deleted, because `deylee_api` holds no DELETE grant on
    /// these tables — the app only ever tombstones, and the test is bound by the same
    /// permissions it is testing. `days_one_live_row_per_date` is partial on
    /// `deleted_at IS NULL`, so the next run can use the same date again.
    private func removeDays(_ store: Store, _ ids: [UUID]) async throws {
        for id in ids {
            try await store.withUser(id) { connection in
                _ = try await connection.query(
                    """
                    UPDATE public.days SET deleted_at = 1
                     WHERE user_id = \(id) AND deleted_at IS NULL
                    """,
                    logger: Logger(label: "clean")
                ).collect()
            }
        }
    }

    /// Without this the rest of the suite is theatre: every assertion below passes
    /// trivially when the connection is a role policies do not apply to.
    @Test func roleCannotBypassPolicies() async throws {
        try await withStore { store in
            try await store.assertNotBypassingRowLevelSecurity()
        }
    }

    /// The one this whole product rests on.
    @Test func neitherUserCanSeeTheOthersRows() async throws {
        try await withStore { store in
            let (a, b) = try await self.seedTwoUsers(store)
            defer { Task { try? await self.removeDays(store, [a, b]) } }

            for (id, date) in [(a, "2026-03-01"), (b, "2026-03-01")] {
                try await store.withUser(id) { connection in
                    _ = try await connection.query(
                        """
                        INSERT INTO public.days (id, user_id, date, target_minutes)
                        VALUES (\(UUID()), \(id), \(date), 480)
                        """,
                        logger: Logger(label: "push")
                    ).collect()
                }
            }

            for (mine, theirs) in [(a, b), (b, a)] {
                let owners = try await store.withUser(mine) { connection -> [UUID] in
                    // Deliberately unfiltered, the way the pull query used to be. What
                    // comes back is whatever the database is willing to show this
                    // connection, which is exactly the layer under test.
                    let rows = try await connection.query(
                        "SELECT user_id FROM public.days", logger: Logger(label: "pull")
                    )
                    var out: [UUID] = []
                    for try await row in rows.decode(UUID.self) { out.append(row) }
                    return out
                }
                #expect(owners.contains(mine), "a user must see their own rows")
                #expect(!owners.contains(theirs), "and none of anybody else's")
            }

            try await self.removeDays(store, [a, b])
        }
    }

    /// `tombstone` takes a client-supplied id and deletes by primary key. With
    /// policies inactive, one authenticated user could delete any row in the system by
    /// learning a uuid — the sharpest edge in the audit.
    @Test func aUserCannotTombstoneSomebodyElsesRow() async throws {
        try await withStore { store in
            let (a, b) = try await self.seedTwoUsers(store)
            let victimRow = UUID()

            try await store.withUser(b) { connection in
                _ = try await connection.query(
                    """
                    INSERT INTO public.days (id, user_id, date, target_minutes)
                    VALUES (\(victimRow), \(b), '2026-03-02', 480)
                    """,
                    logger: Logger(label: "push")
                ).collect()
            }

            // A knows the id and asks for it by primary key, as the route does.
            try await store.withUser(a) { connection in
                _ = try await connection.query(
                    """
                    UPDATE public.days SET deleted_at = 9999 WHERE id = \(victimRow)
                    """,
                    logger: Logger(label: "attack")
                ).collect()
            }

            let stillLive = try await store.withUser(b) { connection -> Bool in
                let rows = try await connection.query(
                    "SELECT deleted_at FROM public.days WHERE id = \(victimRow)",
                    logger: Logger(label: "check")
                )
                for try await deletedAt in rows.decode(Int64?.self) { return deletedAt == nil }
                return false
            }
            #expect(stillLive, "one user tombstoned another user's row")

            try await self.removeDays(store, [a, b])
        }
    }
}
