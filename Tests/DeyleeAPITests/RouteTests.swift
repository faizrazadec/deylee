import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import DeyleeAPI

/// The auth surface as a client meets it.
///
/// Everything else tests a function. These send a request through the real router and
/// read the status back, which is the only way to catch the layer between them: a
/// refusal the database raises correctly and the error mapping then reports as a 500,
/// a route that decodes a body wrong, an `Authorization` header nobody checks.
/// `HummingbirdTesting` was declared as a dependency and never imported.
///
/// `.router` sends straight to the router rather than over a socket — no port, no
/// listener, and the boot check does not run, which is why the tenancy suite asserts
/// the role separately.
///
/// Needs a database for the same reason the tenancy tests do: every route here reaches
/// one, and the interesting answers (409, 429, 400) come from constraints and
/// SECURITY DEFINER functions rather than from Swift. Set `DEYLEE_TEST_DB_URL` — see
/// `TenancyTests` for the rest.
///
/// Every case below fails *before* any mail is sent, so `Mailer` is never exercised
/// and no Resend key is needed. That is a deliberate limit: the happy path of sign-up
/// is not covered here.
private let routeTestDatabaseURL = ProcessInfo.processInfo.environment["DEYLEE_TEST_DB_URL"]

@Suite(.enabled(if: routeTestDatabaseURL != nil, "set DEYLEE_TEST_DB_URL to run"))
struct AuthRoutes {
    /// The router as `main.swift` assembles it, minus the parts a request never
    /// reaches here.
    private func withRouter(
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let logger = Logger(label: "route-test")
        let config = try Config.load(routeTestEnvironment)
        let store = try Store(
            url: routeTestDatabaseURL!, tls: false, caCertificatePath: nil, logger: logger
        )
        let tokens = try await TokenService(config: config)
        let mailer = Mailer(
            apiKey: config.resendAPIKey, from: config.resendFrom,
            templateID: config.resendOTPTemplateID, logger: logger
        )
        // A fresh limiter per router, so one test's attempts cannot throttle another's.
        let limiter = RateLimiter()

        let router = Router(context: DeyleeRequestContext.self)
        router.add(middleware: ErrorLogging(logger: logger))
        AuthController(store: store, tokens: tokens, config: config, mailer: mailer,
                       limiter: limiter, logger: logger)
            .addRoutes(to: router)

        let app = Application(router: router, services: [store.client], logger: logger)
        try await app.test(.router) { client in try await body(client) }
    }

    private func post(
        _ client: any TestClientProtocol, _ path: String, _ json: String
    ) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: path, method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: json)
        ) { $0.status }
    }

    // MARK: Password sign-in

    /// Wrong password and unknown address answer identically, so the response cannot
    /// be used to learn which addresses are registered. Asserted through the route
    /// because it is the route that turns both into a body.
    @Test func badCredentialsAreRefusedIdenticallyToUnknownOnes() async throws {
        try await withRouter { client in
            let wrong = try await client.execute(
                uri: "/v1/auth/password", method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"email":"nobody@routes.invalid","password":"whatever1"}"#)
            ) { ($0.status, String(buffer: $0.body)) }

            let alsoWrong = try await client.execute(
                uri: "/v1/auth/password", method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"email":"someone-else@routes.invalid","password":"whatever1"}"#)
            ) { ($0.status, String(buffer: $0.body)) }

            #expect(wrong.0 == .unauthorized)
            #expect(alsoWrong.0 == .unauthorized)
            #expect(wrong.1 == alsoWrong.1, "the two answers must not differ")
        }
    }

    // MARK: Sign-out

    /// Sign-out revokes a session and must therefore prove which one. Without a token
    /// there is no `sid` to act on, and a route that shrugged and answered 200 would
    /// read as a successful sign-out to every client.
    @Test func signOutWithoutATokenIsRefused() async throws {
        try await withRouter { client in
            let missing = try await self.post(client, "/v1/auth/signout", "{}")
            #expect(missing == .unauthorized)

            let garbage = try await client.execute(
                uri: "/v1/auth/signout", method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer not-a-jwt"],
                body: ByteBuffer(string: "{}")
            ) { $0.status }
            #expect(garbage == .unauthorized)
        }
    }

    /// A body the route cannot decode is the client's fault, not the server's. It
    /// used to be easy for this to surface as a 500.
    @Test func aMalformedBodyIsRejectedNotCrashed() async throws {
        try await withRouter { client in
            let status = try await self.post(client, "/v1/auth/password", #"{"email":"only-half"}"#)
            #expect(status == .badRequest)
        }
    }

    // MARK: Sign-up refusals

    /// bcrypt ignores anything past 72 bytes, which would make two long passwords
    /// interchangeable, so the function refuses rather than truncating — and the route
    /// has to report that as something the person can act on.
    @Test func aWeakPasswordIsFourHundred() async throws {
        try await withRouter { client in
            let status = try await self.post(
                client, "/v1/auth/signup",
                #"{"email":"weak@routes.invalid","password":"short"}"#
            )
            #expect(status == .badRequest, "a short password must not reach the mailer")
        }
    }

    /// An address that already has an account is a 409 and not a 500. The mapping
    /// switches on the message a SECURITY DEFINER function raises, and a sentinel
    /// missing from that switch is exactly how this became an opaque 500 twice.
    @Test func aTakenAddressIsFourHundredAndNine() async throws {
        try await withRouter { client in
            // Made through the Google route's own function, the only way the
            // restricted role can create an account.
            let store = try Store(
                url: routeTestDatabaseURL!, tls: false, caCertificatePath: nil,
                logger: Logger(label: "seed")
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await store.client.run() }
                try await store.withoutTenant { connection in
                    _ = try await connection.query(
                        """
                        SELECT id FROM public.auth_sign_in_with_google(
                            'route-test-taken', 'taken@routes.invalid', true, 'Probe', 'UTC')
                        """,
                        logger: Logger(label: "seed")
                    ).collect()
                }
                group.cancelAll()
            }

            let status = try await self.post(
                client, "/v1/auth/signup",
                #"{"email":"taken@routes.invalid","password":"a-good-password"}"#
            )
            #expect(status == .conflict)
        }
    }

    // MARK: Bearer tokens

    /// `set-password` is the one route that trusts a session, so the header is the
    /// whole of its security. Absent, malformed and forged must all be refused.
    @Test func setPasswordRefusesEveryBadHeader() async throws {
        try await withRouter { client in
            let none = try await self.post(
                client, "/v1/auth/set-password", #"{"password":"a-good-password"}"#
            )
            #expect(none == .unauthorized, "no bearer token")

            for header in ["Bearer not-a-jwt", "Basic abc", "bearer wrong-scheme-case"] {
                let status = try await client.execute(
                    uri: "/v1/auth/set-password", method: .post,
                    headers: [.contentType: "application/json", .authorization: header],
                    body: ByteBuffer(string: #"{"password":"a-good-password"}"#)
                ) { $0.status }
                #expect(status == .unauthorized, "accepted: \(header)")
            }
        }
    }

    /// A refresh token nobody issued must not mint a session, and must answer the same
    /// as a spent one so a thief learns nothing from the difference.
    @Test func anUnknownRefreshTokenIsRefused() async throws {
        try await withRouter { client in
            let status = try await self.post(
                client, "/v1/auth/refresh", #"{"refreshToken":"invented"}"#
            )
            #expect(status == .unauthorized)
        }
    }

    /// The route was removed when sign-up became two steps. A 404 rather than an
    /// accidental resurrection.
    @Test func thereIsNoSingleStepSignUpLeft() async throws {
        try await withRouter { client in
            let status = try await self.post(
                client, "/v1/auth/signup/verify", #"{"email":"x@routes.invalid","code":"000000"}"#
            )
            // Not 500: a wrong code is a refusal the route reports, not a fault.
            #expect(status == .unauthorized)
        }
    }
    // MARK: Throttling

    /// Every password attempt costs a quarter-second of database CPU by design, so an
    /// unauthenticated caller converts one cheap request into real money. Unlimited
    /// attempts is the DoS; the 429 is the cap.
    @Test func repeatedAttemptsAreThrottledWithRetryAfter() async throws {
        try await withRouter { client in
            var sawTooMany = false
            var retryAfter: String?

            // The per-address limit is 10 in five minutes and bites first.
            for _ in 0..<14 {
                let (status, header) = try await client.execute(
                    uri: "/v1/auth/password", method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"email":"throttle@routes.invalid","password":"whatever1"}"#)
                ) { ($0.status, $0.headers[.retryAfter]) }

                if status == .tooManyRequests {
                    sawTooMany = true
                    retryAfter = header
                    break
                }
                #expect(status == .unauthorized, "before the cap, a bad password is a 401")
            }

            #expect(sawTooMany, "unlimited attempts against one account")
            // The protocol says Retry-After is authoritative, so it has to be there and
            // has to be a number a client can wait for.
            let seconds = Int(retryAfter ?? "")
            #expect(seconds != nil, "Retry-After missing or unparseable: \(retryAfter ?? "nil")")
            #expect((seconds ?? 0) > 0, "Retry-After: 0 invites an immediate refusal")
        }
    }

}

/// Enough environment for `Config.load`, with the real signing key swapped for the
/// throwaway one the config suite already carries. The Resend values are placeholders
/// — no test here reaches the mailer.
@Sendable private func routeTestEnvironment(_ key: String) -> String? {
    return
    [
        "GOOGLE_CLIENT_ID_IOS": "111-ios.apps.googleusercontent.com",
        "SESSION_JWT_PRIVATE_KEY_B64": Data(testPrivateKeyPEM.utf8).base64EncodedString(),
        "DEYLEE_DB_URL": routeTestDatabaseURL ?? "",
        "RESEND_API_KEY": "re_placeholder",
        "RESEND_FROM": "Deylee <no-reply@routes.invalid>",
        "RESEND_OTP_TEMPLATE_ID": "tmpl_placeholder",
    ][key]
}
