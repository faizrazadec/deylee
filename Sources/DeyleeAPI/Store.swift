import Foundation
import Logging
import NIOSSL
import PostgresNIO

/// Postgres access, with tenancy attached to the transaction rather than to the
/// query.
///
/// Every request that touches a user's rows goes through ``withUser(_:_:)``, which
/// opens a transaction and sets `app.user_id` inside it. The row-level security
/// policies read that variable, so a query which forgets its `where user_id = …`
/// still returns nothing rather than everything. The application filters and the
/// database filters, and both have to fail before one customer sees another's
/// hours.
///
/// `set local` is what makes this safe under pooling: it reverts when the
/// transaction ends, so a connection handed to the next request cannot still be
/// carrying the last one's identity.
struct Store: Sendable {
    let client: PostgresClient
    let logger: Logger

    init(url: String, tls useTLS: Bool = true, caCertificatePath: String?, logger: Logger) throws {
        // `backgroundLogger` explicitly, because the shorter init substitutes a
        // disabled logger. That silences the pool itself — connection creation,
        // leasing, keep-alive — which is exactly the layer that was stalling when
        // requests hung with nothing in the log at any level.
        self.client = PostgresClient(
            configuration: try Store.configuration(
                from: url, tls: useTLS, caCertificatePath: caCertificatePath
            ),
            backgroundLogger: logger
        )
        self.logger = logger

        if useTLS, caCertificatePath == nil {
            logger.warning("""
                database TLS is encrypted but UNVERIFIED — set DEYLEE_DB_CA_CERT to \
                Supabase's CA certificate to authenticate the server
                """)
        }
    }

    /// Parse a `postgresql://user:password@host:port/database` URL.
    ///
    /// Hand-rolled because PostgresNIO takes its configuration in parts. The
    /// password is percent-decoded: a generated one can legitimately contain
    /// characters that must be escaped in a URL, and passing the escaped form
    /// through would fail authentication with a message about the password being
    /// wrong — which it technically would be.
    static func configuration(
        from url: String, tls useTLS: Bool = true, caCertificatePath: String? = nil
    ) throws -> PostgresClient.Configuration {
        guard let components = URLComponents(string: url),
              let host = components.host,
              let user = components.user
        else {
            throw StoreError.malformedURL
        }
        let database = components.path.hasPrefix("/")
            ? String(components.path.dropFirst())
            : components.path

        // Always `require`, never `prefer`: silently dropping to an unencrypted
        // connection would put every customer's hours on the wire in the clear.
        //
        // Whether the server is *authenticated* as well as encrypted is a separate
        // question, and on Supabase it needs saying out loud. Its direct Postgres
        // endpoint presents a certificate signed by Supabase's own CA, not by a
        // publicly-trusted one, so verifying against the system trust store fails —
        // which is why psql connects (its default sslmode encrypts without
        // verifying) while a verifying client does not.
        //
        // Point DEYLEE_DB_CA_CERT at the CA certificate from the Supabase dashboard
        // and the connection is both encrypted and authenticated. Without it the
        // traffic is still encrypted, but nothing proves the far end is actually
        // your database, which leaves a machine-in-the-middle able to read
        // everything. The fallback exists so this runs out of the box; the warning
        // in `init` exists so nobody ships it that way by accident.
        var tls = PostgresClient.Configuration.TLS.disable
        if useTLS {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            if let caCertificatePath {
                tlsConfig.trustRoots = .file(caCertificatePath)
            } else {
                tlsConfig.certificateVerification = .none
            }
            tls = .require(tlsConfig)
        }

        var configuration = PostgresClient.Configuration(
            host: host,
            port: components.port ?? 5432,
            username: user.removingPercentEncoding ?? user,
            password: components.password?.removingPercentEncoding ?? components.password,
            database: database.isEmpty ? "postgres" : database,
            tls: tls
        )

        // The pool keeps none open by default, so a request arriving after any quiet
        // spell pays to build a connection from nothing: TCP, TLS and authentication
        // against a database that may be on another continent. Keeping a couple warm
        // is what stops the first sign-in of the day being the one that stalls.
        configuration.options.minimumConnections = 2
        // One attempt to open a connection, bounded — and deliberately shorter than
        // `deadline`, so a connection that will not open fails while there is still
        // time left for the pool to try another one.
        configuration.options.connectTimeout = .seconds(5)
        return configuration
    }

    /// How long a request may spend waiting on the database before it is refused.
    ///
    /// Generous on purpose. A sign-in against a database on the far side of the world
    /// legitimately takes a couple of seconds, and bcrypt is slow by design. This is
    /// the bound past which something is wrong, not a latency target.
    static let deadline: Duration = .seconds(15)

    /// Run `body`, refusing rather than hanging when the database does not answer.
    ///
    /// `withConnection` waits for a lease from the pool with no bound of its own, and
    /// `connectTimeout` bounds a single attempt to open a connection rather than the
    /// wait for one. So when the far end is unreachable the pool retries behind the
    /// lease and the request simply stops — until the caller gives up. Somebody
    /// signing in sees a spinner that never resolves, which is the one failure a
    /// person cannot act on.
    ///
    /// Deliberately NOT a task group racing a sleep. A group must await its children
    /// before it returns, so a child that ignores cancellation holds the deadline
    /// hostage and the request hangs anyway — observed, not hypothesised: a query
    /// enqueued on a connection PostgresNIO had just condemned resolves its promise
    /// never, and no cancellation reaches it. The stream answers whichever finishes
    /// first and the loser is abandoned to finish or hang on its own, logged, without
    /// a caller attached.
    func withDeadline<T: Sendable>(
        _ deadline: Duration = Store.deadline,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream()
        let work = Task {
            do {
                continuation.yield(try await body())
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            continuation.finish(throwing: StoreError.timedOut)
        }

        do {
            for try await value in stream {
                timer.cancel()
                return value
            }
            // The stream finished without a value or an error, which only the
            // deadline's plain `finish` could cause — treat it as the timeout it is.
            throw StoreError.timedOut
        } catch {
            timer.cancel()
            if case StoreError.timedOut = error {
                // A cancellation the body honours turns the orphan into a clean
                // early exit; one it cannot honour leaves it hanging harmlessly,
                // already answered for.
                work.cancel()
                logger.warning("abandoning a database call at the deadline")
            }
            throw error
        }
    }

    /// Run `body` inside a transaction scoped to one user.
    ///
    /// The advisory lock serialises writes per user, which is what makes the sync
    /// cursor safe: sequence values are handed out when a row is written but
    /// transactions commit in a different order, so without this a pull can step
    /// past a row that has not committed yet and never see it again.
    ///
    /// Locking per user rather than globally means two customers still write
    /// concurrently; only one person's own devices queue behind each other, and
    /// they are rarely writing at the same instant anyway.
    func withUser<T: Sendable>(
        _ userID: UUID,
        lockForWrite: Bool = false,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        try await withDeadline {
            try await self.client.withConnection { connection in
                try await connection.query("BEGIN", logger: self.logger)
                do {
                    // Interpolation into a PostgresQuery produces a bind parameter,
                    // not string concatenation — parameterised, not injected.
                    if lockForWrite {
                        _ = try await connection.query(
                            """
                            SELECT pg_advisory_xact_lock(\
                            hashtextextended(\(userID.uuidString), 0))
                            """,
                            logger: self.logger
                        ).collect()
                    }
                    // `set_config` rather than `SET LOCAL`, because SET takes no
                    // parameters and would leave the user id to be pasted into SQL.
                    _ = try await connection.query(
                        "SELECT set_config('app.user_id', \(userID.uuidString), true)",
                        logger: self.logger
                    ).collect()

                    let result = try await body(connection)
                    try await connection.query("COMMIT", logger: self.logger)
                    return result
                } catch {
                    if !Self.condemnsConnection(error) {
                        try? await connection.query("ROLLBACK", logger: self.logger)
                    }
                    throw error
                }
            }
        }
    }

    /// A transaction with no tenancy set.
    ///
    /// Sign-in and refresh legitimately run before any user is known, and they
    /// touch `app_users` and `refresh_tokens`, neither of which a user-scoped
    /// connection can reach. Everything else must use ``withUser(_:lockForWrite:_:)``.
    func withoutTenant<T: Sendable>(
        _ body: @escaping @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        try await withDeadline {
            try await self.client.withConnection { connection in
                try await connection.query("BEGIN", logger: self.logger)
                do {
                    let result = try await body(connection)
                    try await connection.query("COMMIT", logger: self.logger)
                    return result
                } catch {
                    if !Self.condemnsConnection(error) {
                        try? await connection.query("ROLLBACK", logger: self.logger)
                    }
                    throw error
                }
            }
        }
    }

    /// Whether this error has already cost the connection its life.
    ///
    /// PostgresNIO closes the connection outright on any server error in SQLSTATE
    /// class 28 — the class Postgres uses for *connection* authentication — however
    /// the error actually arose (`ConnectionStateMachine.shouldCloseConnection`). A
    /// ROLLBACK sent to that connection races its teardown, and losing the race
    /// means a promise nobody will ever resolve: the request hangs forever, holding
    /// its lease. The transaction needs no goodbye anyway — the server aborts it
    /// when the connection drops.
    ///
    /// The schema's own rule is that no function raises class 28 (see the
    /// sign_in_error_code migration), so this guard is for the codes the schema
    /// cannot promise away: a revoked role, an expired password, a proxy in front
    /// of the database speaking for it.
    static func condemnsConnection(_ error: any Error) -> Bool {
        condemnsConnection(sqlState: (error as? PSQLError)?.serverInfo?[.sqlState])
    }

    /// The rule itself, on the bare SQLSTATE so a test can reach it.
    static func condemnsConnection(sqlState: String?) -> Bool {
        sqlState?.hasPrefix("28") ?? false
    }
}

enum StoreError: Error, CustomStringConvertible {
    case malformedURL
    /// The database did not answer inside ``Store/deadline``. A refusal the caller
    /// can show, rather than a request that never comes back.
    case timedOut
    /// The connected role skips row-level security, so every tenancy policy in the
    /// schema is inert. Refused at boot rather than served.
    case bypassesRowLevelSecurity(role: String)

    /// What a client is told when the deadline is hit. Kept here because two layers
    /// translate this error — the auth routes, which swallow everything into an
    /// `HTTPError` of their own, and the middleware behind every other route — and
    /// two copies of the sentence would drift.
    static let unavailableMessage =
        "Deylee could not reach its database. Please try again in a moment."

    var description: String {
        switch self {
        case .malformedURL:
            "DEYLEE_DB_URL is not a postgresql:// URL with a host and username."
        case .timedOut:
            "The database did not answer in time."
        case .bypassesRowLevelSecurity(let role):
            """
            DEYLEE_DB_URL connects as '\(role)', which bypasses row-level security. \
            Every tenancy policy would be skipped and one customer's sync would read \
            another's hours. Point it at the restricted login (deylee_api), not \
            SUPABASE_DB_URL.
            """
        }
    }
}

extension Store {
    /// Refuse to serve as a role that row-level security does not apply to.
    ///
    /// Tenancy rests on the policies binding, and they bind only to an ordinary role.
    /// A superuser, or one holding BYPASSRLS, skips every policy — silently. Nothing
    /// else would look wrong: the connection succeeds, the health check passes, the
    /// log says `listening`, and every sync then reads and tombstones every
    /// customer's rows.
    ///
    /// The misconfiguration is one character of `.env` away, because
    /// `SUPABASE_DB_URL` connects as `postgres` and sits directly above
    /// `DEYLEE_DB_URL` in the file. Checked at boot rather than per request: this
    /// cannot change while the process runs, and a process that would serve every
    /// tenant's data to whoever asks should not start at all.
    func assertNotBypassingRowLevelSecurity() async throws {
        let (role, isSuper, bypasses) = try await withoutTenant { connection in
            let rows = try await connection.query(
                "SELECT current_user::text, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user",
                logger: self.logger
            )
            for try await row in rows.decode((String, Bool, Bool).self) { return row }
            // No matching row means the role is not in pg_roles at all, which should
            // be impossible for the role we are connected as. Unknown is not safe.
            return ("unknown", true, true)
        }

        guard !isSuper, !bypasses else {
            throw StoreError.bypassesRowLevelSecurity(role: role)
        }
        logger.info("tenancy enforced", metadata: ["role": .string(role)])
    }
}
