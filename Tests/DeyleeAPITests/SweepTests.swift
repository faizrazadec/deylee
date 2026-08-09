import Foundation
import Logging
import PostgresNIO
import Testing

@testable import DeyleeAPI

/// The refresh-token sweep, and specifically its grace window.
///
/// The window is the only interesting part: too long and the table keeps growing, too
/// short and `auth_rotate_refresh_token` stops being able to say `replayed` — a stolen
/// token then reads as `unknown`, indistinguishable from a client sending nonsense,
/// and the theft signal is gone. Both failures are silent, which is why this exists.
///
/// Same database gate as the other server suites; see `TenancyTests`.
private let sweepTestDatabaseURL = ProcessInfo.processInfo.environment["DEYLEE_TEST_DB_URL"]

// Serialized: the sweep deletes by expiry across the whole table, not per user, so two
// of these running at once delete each other's rows and both report the wrong count.
@Suite(
    .enabled(if: sweepTestDatabaseURL != nil, "set DEYLEE_TEST_DB_URL to run"),
    .serialized
)
struct RefreshTokenSweep {
    private static let day: Int64 = 86_400_000

    private func withStore(_ body: @escaping @Sendable (Store) async throws -> Void) async throws {
        let store = try Store(
            url: sweepTestDatabaseURL!, tls: false, caCertificatePath: nil,
            logger: Logger(label: "sweep-test")
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await store.client.run() }
            do { try await body(store) } catch { group.cancelAll(); throw error }
            group.cancelAll()
        }
    }

    /// An account to hang the tokens off, through the one function the restricted role
    /// can create one with.
    private func probeUser(_ store: Store) async throws -> UUID {
        try await store.withoutTenant { connection in
            let rows = try await connection.query(
                """
                SELECT id FROM public.auth_sign_in_with_google(
                    'sweep-test', 'sweep@sweep.invalid', true, 'Probe', 'UTC')
                """,
                logger: Logger(label: "seed")
            )
            for try await id in rows.decode(UUID.self) { return id }
            throw StoreError.malformedURL
        }
    }

    /// Issued through the real function, because `refresh_tokens` has row-level
    /// security enabled with no policies at all: nothing but a SECURITY DEFINER
    /// function may write there, which is exactly the shape it should be. A test
    /// cannot plant an already-expired row, and should not be able to.
    ///
    /// So the boundary is approached from the other side. The sweep deletes rows whose
    /// expiry is older than `now - grace`; a negative grace moves that cutoff into the
    /// future, which exercises the same arithmetic on rows the test is allowed to make.
    private func issueToken(_ store: Store, user: UUID, expiresInDays: Int64) async throws {
        let hash = RefreshToken.digest(RefreshToken.generate())
        let expiry = Int64(Date().timeIntervalSince1970 * 1000) + expiresInDays * Self.day
        try await store.withoutTenant { connection in
            _ = try await connection.query(
                """
                SELECT public.auth_issue_refresh_token(
                    \(user), \(UUID()), \(ByteBuffer(bytes: hash)), \(UUID()), \(expiry))
                """,
                logger: Logger(label: "issue")
            ).collect()
        }
    }

    private func sweep(_ store: Store, graceDays: Int) async throws -> Int {
        try await store.withoutTenant { connection in
            let rows = try await connection.query(
                "SELECT public.auth_sweep_expired_refresh_tokens(\(graceDays))",
                logger: Logger(label: "sweep")
            )
            for try await n in rows.decode(Int.self) { return n }
            return -1
        }
    }

    /// The cutoff, and that it is a cutoff rather than a wipe.
    @Test func sweepsOnlyWhatIsPastTheCutoff() async throws {
        try await withStore { store in
            let user = try await self.probeUser(store)
            // The count it returns is the only observable: refresh_tokens has RLS on
            // with no policies, so the restricted role cannot read the table either —
            // which is the correct shape, and means the sweep reports its own work.
            _ = try await self.sweep(store, graceDays: -3650)  // clear anything left behind

            try await self.issueToken(store, user: user, expiresInDays: 10)
            try await self.issueToken(store, user: user, expiresInDays: 90)

            // Cutoff at now + 30 days: the token expiring in 10 is behind it, the one
            // expiring in 90 is not.
            #expect(try await self.sweep(store, graceDays: -30) == 1, "only the row past the cutoff")
            // And the survivor really did survive, rather than never having been there.
            #expect(try await self.sweep(store, graceDays: -3650) == 1, "the 90-day row was kept")
        }
    }

    /// The default window is what actually runs on the schedule, and it must not touch
    /// a live token. Sweeping at the default with only live rows present has to be a
    /// no-op — the failure this guards against is a sweep that logs people out.
    @Test func theDefaultWindowLeavesLiveTokensAlone() async throws {
        try await withStore { store in
            let user = try await self.probeUser(store)
            _ = try await self.sweep(store, graceDays: -3650)

            try await self.issueToken(store, user: user, expiresInDays: 90)

            #expect(try await self.sweep(store, graceDays: 30) == 0,
                    "the scheduled sweep must never take a live session")
            #expect(try await self.sweep(store, graceDays: -3650) == 1, "it was still there")
        }
    }
}
