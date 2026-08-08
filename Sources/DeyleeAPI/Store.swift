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
        self.client = PostgresClient(
            configuration: try Store.configuration(
                from: url, tls: useTLS, caCertificatePath: caCertificatePath
            )
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

        return PostgresClient.Configuration(
            host: host,
            port: components.port ?? 5432,
            username: user.removingPercentEncoding ?? user,
            password: components.password?.removingPercentEncoding ?? components.password,
            database: database.isEmpty ? "postgres" : database,
            tls: tls
        )
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
        _ body: @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        try await client.withConnection { connection in
            try await connection.query("BEGIN", logger: logger)
            do {
                // Interpolation into a PostgresQuery produces a bind parameter, not
                // string concatenation — these are parameterised, not injected.
                if lockForWrite {
                    _ = try await connection.query(
                        "SELECT pg_advisory_xact_lock(hashtextextended(\(userID.uuidString), 0))",
                        logger: logger
                    ).collect()
                }
                // `set_config` rather than `SET LOCAL`, because SET takes no
                // parameters and would leave the user id to be pasted into SQL.
                _ = try await connection.query(
                    "SELECT set_config('app.user_id', \(userID.uuidString), true)",
                    logger: logger
                ).collect()

                let result = try await body(connection)
                try await connection.query("COMMIT", logger: logger)
                return result
            } catch {
                try? await connection.query("ROLLBACK", logger: logger)
                throw error
            }
        }
    }

    /// A transaction with no tenancy set.
    ///
    /// Sign-in and refresh legitimately run before any user is known, and they
    /// touch `app_users` and `refresh_tokens`, neither of which a user-scoped
    /// connection can reach. Everything else must use ``withUser(_:lockForWrite:_:)``.
    func withoutTenant<T: Sendable>(
        _ body: @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        try await client.withConnection { connection in
            try await connection.query("BEGIN", logger: logger)
            do {
                let result = try await body(connection)
                try await connection.query("COMMIT", logger: logger)
                return result
            } catch {
                try? await connection.query("ROLLBACK", logger: logger)
                throw error
            }
        }
    }
}

enum StoreError: Error, CustomStringConvertible {
    case malformedURL

    var description: String {
        switch self {
        case .malformedURL:
            "DEYLEE_DB_URL is not a postgresql:// URL with a host and username."
        }
    }
}
