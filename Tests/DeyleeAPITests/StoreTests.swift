import Foundation
import Testing

@testable import DeyleeAPI

/// The pool settings, which are the difference between a request that fails and a
/// request that never comes back.
///
/// Neither of these can be proved by a test that talks to a database — an
/// unreachable one is exactly what the defaults handled badly, and a reachable one
/// never exercises the path. What is worth pinning is the configuration itself,
/// because both values were wrong by default and silently so.
@Suite struct StorePooling {
    private static let url = "postgresql://someone:secret@db.example.invalid:5432/postgres"

    /// Zero was the default, so the pool held nothing open and every request after a
    /// quiet spell paid to build a connection from nothing. On a database across an
    /// ocean that made the first sign-in of the day the one that stalled.
    @Test func keepsConnectionsWarm() throws {
        let configuration = try Store.configuration(
            from: Self.url, tls: false, caCertificatePath: nil
        )
        #expect(configuration.options.minimumConnections > 0)
    }

    /// The attempt has to give up while the request still has time to spare, or the
    /// pool never gets to try a second connection before the deadline takes the whole
    /// request down.
    @Test func boundsOneAttemptWellInsideTheRequestDeadline() throws {
        let configuration = try Store.configuration(
            from: Self.url, tls: false, caCertificatePath: nil
        )
        #expect(configuration.options.connectTimeout < Store.deadline)
    }

    /// Long enough for honest work. A sign-in against Tokyo measured about 2.5
    /// seconds, most of it bcrypt, so a deadline anywhere near that would refuse
    /// requests that were going to succeed.
    @Test func leavesRoomForASlowButHonestRequest() {
        #expect(Store.deadline > .seconds(10))
    }

    /// The parsing this all sits on, unchanged: a password may legitimately contain
    /// characters that have to be escaped in a URL, and passing the escaped form
    /// through fails authentication with a message about the password being wrong.
    @Test func decodesAPercentEscapedPassword() throws {
        let configuration = try Store.configuration(
            from: "postgresql://someone:p%40ss%2Fword@db.example.invalid:5432/postgres",
            tls: false, caCertificatePath: nil
        )
        #expect(configuration.password == "p@ss/word")
    }

    /// TLS with nothing to verify against used to degrade to
    /// `certificateVerification = .none` and log a warning. A warning is not a control:
    /// one line in a log on a deploy that otherwise succeeds, guarding a failure that
    /// is silent by construction. Anything answering on that host and port would have
    /// received the API's database credentials.
    @Test func refusesEncryptedButUnverifiedTLS() {
        #expect(throws: StoreError.self) {
            _ = try Store.configuration(from: Self.url, tls: true, caCertificatePath: nil)
        }
    }

    /// A path that is not there is caught at boot rather than at the first handshake,
    /// where it surfaces as a connection failure with nothing pointing at the cause.
    @Test func refusesACaCertificateThatIsNotThere() {
        #expect(throws: StoreError.self) {
            _ = try Store.configuration(
                from: Self.url, tls: true, caCertificatePath: "/no/such/ca.crt"
            )
        }
    }

    /// The escape hatch the fallback was really built for: the local development
    /// container, where there is no certificate and nothing on the wire to protect.
    @Test func tlsDisabledNeedsNoCertificate() throws {
        let configuration = try Store.configuration(
            from: Self.url, tls: false, caCertificatePath: nil
        )
        #expect(configuration.options.minimumConnections > 0)
    }

    @Test func refusesAUrlThatIsNotPostgres() {
        #expect(throws: StoreError.self) {
            _ = try Store.configuration(
                from: "not a url at all", tls: false, caCertificatePath: nil
            )
        }
    }
}

/// The deadline race, on a Store that never dials anywhere.
@Suite struct StoreDeadline {
    private static func idle() throws -> Store {
        try Store(
            url: "postgresql://someone:secret@db.example.invalid:5432/postgres",
            tls: false, caCertificatePath: nil, logger: .init(label: "test")
        )
    }

    @Test func answersBeforeTheDeadlineUntouched() async throws {
        let store = try Self.idle()
        let value = try await store.withDeadline(.seconds(5)) { 7 }
        #expect(value == 7)
    }

    @Test func aFailureComesBackAsItself() async throws {
        struct Deliberate: Error {}
        let store = try Self.idle()
        await #expect(throws: Deliberate.self) {
            try await store.withDeadline(.seconds(5)) { throw Deliberate() }
        }
    }

    /// The case the task-group version got wrong: a body that never finishes and
    /// never honours cancellation must still produce an answer. A group awaits its
    /// children before returning, so its deadline could fire and then wait forever
    /// on the very hang it had just detected.
    @Test func refusesWhenTheBodyHangsEvenAgainstCancellation() async throws {
        let store = try Self.idle()
        let started = ContinuousClock.now
        await #expect(throws: StoreError.self) {
            try await store.withDeadline(.milliseconds(100)) {
                while true {
                    // Swallow the cancellation a plain sleep would honour, standing
                    // in for a promise nobody will ever resolve.
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
        // Well under the body's sleep: proof the answer came from the deadline, not
        // from the body giving up.
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

/// The rule for skipping ROLLBACK on a connection the driver has already closed.
@Suite struct CondemnedConnections {
    /// Class 28 is connection authentication, and PostgresNIO closes the connection
    /// on any error carrying it — a ROLLBACK sent afterwards can hang forever.
    @Test func class28CostsTheConnection() {
        #expect(Store.condemnsConnection(sqlState: "28P01"))
        #expect(Store.condemnsConnection(sqlState: "28000"))
    }

    /// Everything the schema deliberately raises stays rollback-able.
    @Test func ordinaryRejectionsDoNot() {
        for state in ["23505", "23514", "P0001", "P0002", "53300"] {
            #expect(!Store.condemnsConnection(sqlState: state))
        }
    }

    /// No SQLSTATE means the error never came from the server — a closed channel,
    /// a decoding failure. The ROLLBACK attempt is preserved there: on a dead
    /// channel it fails fast rather than hanging, and on a live one it is needed.
    @Test func aMissingStateIsNotACondemnation() {
        #expect(!Store.condemnsConnection(sqlState: nil))
    }
}
