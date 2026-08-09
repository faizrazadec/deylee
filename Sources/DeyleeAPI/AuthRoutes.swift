import Foundation
import Hummingbird
import Logging
import NIOCore
import PostgresNIO

// MARK: - Wire types

struct GoogleSignInRequest: Decodable {
    /// The ID token the client obtained from Google. Proof of identity, never a
    /// session — it expires in about an hour and is used exactly once, here.
    let idToken: String
    let deviceId: UUID?
    /// IANA name, e.g. "Europe/Berlin". Day boundaries are local, so a report
    /// spanning two countries is wrong without it.
    let timezone: String?
}

struct PasswordRequest: Decodable {
    let email: String
    let password: String
    let displayName: String?
    let deviceId: UUID?
    let timezone: String?
}

struct SetPasswordRequest: Decodable {
    let password: String
}

/// Ask for a sign-up code. Carries the password, because the account is built from
/// this request once the code comes back — there is no second chance to collect it.
struct SignupCodeRequest: Decodable {
    let email: String
    let password: String
    let displayName: String?
    let timezone: String?
}

struct VerifyCodeRequest: Decodable {
    let email: String
    let code: String
    let deviceId: UUID?
    let timezone: String?
}

/// What the client needs to draw the code screen without inventing its own copy of
/// the server's constants.
struct CodeSentResponse: Codable, ResponseEncodable {
    /// Seconds until the code stops working.
    let expiresIn: Int
    /// Seconds before another code may be requested.
    let resendIn: Int
}

struct RefreshRequest: Decodable {
    let refreshToken: String
}

struct UserDTO: Codable, ResponseEncodable {
    let id: String
    let email: String
    let displayName: String?
    let timezone: String
}

struct SessionResponse: Codable, ResponseEncodable {
    let accessToken: String
    let refreshToken: String
    /// Seconds, so a client can schedule its own refresh rather than waiting for a
    /// 401 and retrying — which would make every expiry cost a wasted round trip.
    let expiresIn: Int
    let user: UserDTO
}

struct OKResponse: Codable, ResponseEncodable {
    let ok: Bool
}

// MARK: - Routes

/// Sign-in, sign-up and refresh.
///
/// Every database call here goes through a SECURITY DEFINER function rather than a
/// table. Authentication cannot be tenant-scoped — it is what establishes the
/// tenant — so the API's ordinary row-level-security-bound connection cannot read
/// or write these rows at all. The functions are the enumerated exceptions, and
/// the account-linking rules live inside them where both routes share one copy.
struct AuthController: Sendable {
    let store: Store
    let tokens: TokenService
    let config: Config
    let mailer: Mailer
    let logger: Logger

    func addRoutes(to router: Router<BasicRequestContext>) {
        router.post("/v1/auth/google", use: signInWithGoogle)
        router.post("/v1/auth/signup", use: requestSignupCode)
        router.post("/v1/auth/signup/verify", use: verifySignupCode)
        router.post("/v1/auth/password", use: signInWithPassword)
        router.post("/v1/auth/refresh", use: refresh)
        router.post("/v1/auth/set-password", use: setPassword)
    }

    // MARK: Google

    @Sendable
    func signInWithGoogle(
        _ request: Request, context: BasicRequestContext
    ) async throws -> SessionResponse {
        let body = try await request.decode(as: GoogleSignInRequest.self, context: context)

        let claims: GoogleIDToken
        do {
            claims = try await tokens.verifyGoogleIDToken(body.idToken)
        } catch let error as TokenError {
            throw HTTPError(.unauthorized, message: error.description)
        }
        guard let email = claims.email else {
            throw HTTPError(.unauthorized, message: "Google returned no email address.")
        }

        // Adopting an existing account with this address is safe here and only here:
        // Google asserts it verified the mailbox, so whoever holds this token
        // controls it. Sign-up with a password deliberately refuses the reverse.
        let user = try await callReturningUser(
            """
            SELECT id, email, display_name, timezone
            FROM public.auth_sign_in_with_google(
                \(claims.sub.value), \(email), \(claims.emailVerified ?? false),
                \(claims.name), \(body.timezone))
            """
        )
        return try await issueSession(for: user, deviceID: body.deviceId)
    }

    // MARK: Password

    /// Step one of sign-up: park the request and mail a code.
    ///
    /// No account exists when this returns. That is the point — an account nobody has
    /// verified is exactly what let somebody register a stranger's address and keep a
    /// password on the account the real owner was later handed by Google.
    ///
    /// The code is generated here and never stored in the clear. The database keeps
    /// only a bcrypt digest of it, so this process is the last place the digits exist
    /// outside the mail itself.
    @Sendable
    func requestSignupCode(
        _ request: Request, context: BasicRequestContext
    ) async throws -> CodeSentResponse {
        let body = try await request.decode(as: SignupCodeRequest.self, context: context)
        let code = SignupCode.generate()

        // The row is written first. Sending mail for a request the database refused —
        // a taken address, a password too short, a resend inside the cooldown — would
        // hand an attacker a way to post mail to any inbox they can name.
        do {
            try await store.withoutTenant { connection in
                _ = try await connection.query(
                    """
                    SELECT public.auth_request_signup_code(
                        \(body.email), \(body.password), \(body.displayName), \(body.timezone),
                        \(code), \(config.signupCodeTTL), \(config.signupCodeResendCooldown))
                    """,
                    logger: logger
                ).collect()
            }
        } catch {
            throw mapped(error)
        }

        do {
            try await mailer.sendSignupCode(code, to: body.email)
        } catch {
            // The row survives a failed send, holding its cooldown. Saying so plainly
            // beats a code screen waiting on mail that was never accepted.
            logger.error("signup code send failed", metadata: ["error": .string("\(error)")])
            throw HTTPError(
                .badGateway,
                message: "Could not send the code. Try again in a moment."
            )
        }

        logger.info("signup code sent")
        return CodeSentResponse(
            expiresIn: config.signupCodeTTL,
            resendIn: config.signupCodeResendCooldown
        )
    }

    /// Step two: check the code, and only now create the account.
    ///
    /// The function answers with an outcome rather than raising, because a raise
    /// would roll back the attempt counter it had just incremented — the cap would
    /// read as enforced while a script guessed six digits at its leisure. Every
    /// failure answers with the same words, so the response cannot be used to learn
    /// whether an address has a sign-up in flight.
    @Sendable
    func verifySignupCode(
        _ request: Request, context: BasicRequestContext
    ) async throws -> SessionResponse {
        let body = try await request.decode(as: VerifyCodeRequest.self, context: context)

        let (outcome, user) = try await store.withoutTenant {
            connection -> (String, UserDTO?) in
            let rows = try await connection.query(
                """
                SELECT outcome, user_id, email, display_name, timezone
                FROM public.auth_verify_signup_code(\(body.email), \(body.code))
                """,
                logger: logger
            )
            for try await (outcome, id, email, name, zone) in rows.decode(
                (String, UUID?, String?, String?, String?).self
            ) {
                guard let id, let email, let zone else { return (outcome, nil) }
                return (outcome, UserDTO(id: id.uuidString.lowercased(), email: email,
                                         displayName: name, timezone: zone))
            }
            return ("unknown", nil)
        }

        guard outcome == "created", let user else {
            throw HTTPError(.unauthorized, message: Self.codeFailure(outcome))
        }
        return try await issueSession(for: user, deviceID: body.deviceId)
    }

    /// A sentence for each way a code can fail.
    ///
    /// Expiry and a spent attempt budget are told apart from a wrong code on purpose:
    /// all three end the attempt, but only one is worth retyping, and a person who
    /// cannot tell them apart retypes the same dead code until they give up. None of
    /// them reveals whether the address had a request in flight.
    private static func codeFailure(_ outcome: String) -> String {
        switch outcome {
        case "code-expired":
            "That code has expired. Ask for a new one."
        case "too-many-attempts":
            "Too many wrong codes. Ask for a new one."
        case "email-taken":
            "That address already has an account. Sign in instead."
        default:
            "That code is not right."
        }
    }

    @Sendable
    func signInWithPassword(
        _ request: Request, context: BasicRequestContext
    ) async throws -> SessionResponse {
        let body = try await request.decode(as: PasswordRequest.self, context: context)
        let user = try await callReturningUser(
            """
            SELECT id, email, display_name, timezone
            FROM public.auth_sign_in_with_password(\(body.email), \(body.password))
            """
        )
        return try await issueSession(for: user, deviceID: body.deviceId)
    }

    /// Add or change a password on an account the caller is already signed into.
    ///
    /// This is the safe route into password sign-in for someone who started with
    /// Google: the access token has already established who they are, so nothing
    /// further needs proving. It is also why sign-up may refuse a known address
    /// outright rather than inventing an email-verification flow.
    @Sendable
    func setPassword(_ request: Request, context: BasicRequestContext) async throws -> OKResponse {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let payload = try? await tokens.verifyAccessToken(String(header.dropFirst(7))),
              let userID = UUID(uuidString: payload.sub.value)
        else {
            throw HTTPError(.unauthorized, message: "A bearer token is required.")
        }
        let body = try await request.decode(as: SetPasswordRequest.self, context: context)

        do {
            try await store.withoutTenant { connection in
                _ = try await connection.query(
                    "SELECT public.auth_set_password(\(userID), \(body.password))",
                    logger: logger
                ).collect()
            }
        } catch {
            throw mapped(error)
        }
        return OKResponse(ok: true)
    }

    // MARK: Refresh

    /// Trade a refresh token for a new pair, rotating it.
    ///
    /// The rotation function returns an outcome instead of raising, because raising
    /// would roll back the revocation it had just performed — a replay would be
    /// reported while the stolen token quietly stayed alive. Every failure answers
    /// 401 with the same words, so a caller cannot learn from the response whether
    /// a token ever existed.
    @Sendable
    func refresh(_ request: Request, context: BasicRequestContext) async throws -> SessionResponse {
        let body = try await request.decode(as: RefreshRequest.self, context: context)
        let oldHash = ByteBuffer(bytes: RefreshToken.digest(body.refreshToken))
        let newToken = RefreshToken.generate()
        let newHash = ByteBuffer(bytes: RefreshToken.digest(newToken))
        let expiry = Int64(Date().timeIntervalSince1970 * 1000)
            + Int64(config.refreshTokenTTL * 1000)

        let (outcome, user) = try await store.withoutTenant {
            connection -> (String, UserDTO?) in
            let rows = try await connection.query(
                """
                SELECT outcome, user_id, email, display_name, timezone
                FROM public.auth_rotate_refresh_token(\(oldHash), \(newHash), \(expiry))
                """,
                logger: logger
            )
            for try await (outcome, id, email, name, zone) in rows.decode(
                (String, UUID?, String?, String?, String?).self
            ) {
                guard let id, let email, let zone else { return (outcome, nil) }
                return (outcome, UserDTO(id: id.uuidString.lowercased(), email: email,
                                         displayName: name, timezone: zone))
            }
            return ("unknown", nil)
        }

        guard outcome == "rotated", let user else {
            if outcome == "replayed" {
                logger.warning("refresh token replayed; session revoked")
            }
            throw HTTPError(.unauthorized, message: "That session has ended. Sign in again.")
        }

        // The rotated token stays on the same chain, so the access token must carry
        // the same session id or the two would describe different sessions.
        let sessionID = try await store.withoutTenant { connection -> UUID in
            let rows = try await connection.query(
                "SELECT public.auth_session_for_token(\(newHash))", logger: logger
            )
            for try await id in rows.decode(UUID?.self) { if let id { return id } }
            throw HTTPError(.internalServerError, message: "The session could not be renewed.")
        }

        let access = try await tokens.issueAccessToken(
            userID: UUID(uuidString: user.id)!, sessionID: sessionID
        )
        return SessionResponse(
            accessToken: access, refreshToken: newToken,
            expiresIn: Int(config.accessTokenTTL), user: user
        )
    }

    // MARK: Shared

    /// Run a function that returns one user row, translating its refusals.
    private func callReturningUser(_ query: PostgresQuery) async throws -> UserDTO {
        do {
            return try await store.withoutTenant { connection -> UserDTO in
                let rows = try await connection.query(query, logger: logger)
                for try await (id, email, name, zone) in rows.decode(
                    (UUID, String, String?, String).self
                ) {
                    return UserDTO(id: id.uuidString.lowercased(), email: email,
                                   displayName: name, timezone: zone)
                }
                throw HTTPError(.unauthorized, message: "Those details were not accepted.")
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            throw mapped(error)
        }
    }

    private func issueSession(for user: UserDTO, deviceID: UUID?) async throws -> SessionResponse {
        let sessionID = UUID()
        let refreshToken = RefreshToken.generate()
        let expiry = Int64(Date().timeIntervalSince1970 * 1000)
            + Int64(config.refreshTokenTTL * 1000)

        try await store.withoutTenant { connection in
            _ = try await connection.query(
                """
                SELECT public.auth_issue_refresh_token(
                    \(UUID(uuidString: user.id)!), \(sessionID),
                    \(ByteBuffer(bytes: RefreshToken.digest(refreshToken))),
                    \(deviceID), \(expiry))
                """,
                logger: logger
            ).collect()
        }

        let access = try await tokens.issueAccessToken(
            userID: UUID(uuidString: user.id)!, sessionID: sessionID
        )
        logger.info("session issued", metadata: ["user": .string(user.id)])

        return SessionResponse(
            accessToken: access, refreshToken: refreshToken,
            expiresIn: Int(config.accessTokenTTL), user: user
        )
    }

    /// Turn a function's refusal into something a person can act on.
    ///
    /// Wrong password and unknown address both become the same sentence on purpose:
    /// distinguishing them would let anyone test which addresses are registered.
    private func mapped(_ error: any Error) -> HTTPError {
        // 503 rather than 500, because this one is worth retrying and the other is
        // not. The distinction is the whole reason the deadline exists: without it
        // the request would still be waiting, and a client cannot retry something
        // that has not finished failing.
        if case StoreError.timedOut = error {
            return HTTPError(.serviceUnavailable, message: StoreError.unavailableMessage)
        }
        guard let psql = error as? PSQLError,
              let message = psql.serverInfo?[.message]
        else {
            return HTTPError(.internalServerError, message: "The request could not be completed.")
        }
        switch message {
        case "email-taken":
            return HTTPError(
                .conflict,
                message: "That email already has an account. Sign in instead — "
                    + "if you created it with Google, use Continue with Google."
            )
        case "weak-password":
            return HTTPError(.badRequest, message: "Passwords must be 8 to 72 characters.")
        case "resend-too-soon":
            // Not a failure from where the person is standing: a code is already in
            // their inbox and still good. Answering 429 rather than 500 is what lets
            // the client take them to the code screen instead of a dead end.
            return HTTPError(
                .tooManyRequests,
                message: "A code was already sent to that address. Check your email."
            )
        case "email-collision":
            // The address Google now reports already belongs to a different account
            // here. The sign-in itself was fine, so this says which of the two facts
            // is in the way rather than reporting a failure at Google.
            return HTTPError(
                .conflict,
                message: "That Google address already belongs to another Deylee "
                    + "account. Sign in to that one, or change the address on one of them."
            )
        case "unverified-email":
            return HTTPError(.unauthorized, message: "Google has not verified that address.")
        case "invalid-credentials":
            return HTTPError(.unauthorized, message: "That email and password do not match.")
        case "no-such-user":
            return HTTPError(.unauthorized, message: "That account no longer exists.")
        default:
            return unexplained(error)
        }
    }

    /// The generic 500 — but never a silent one.
    ///
    /// Returning the same opaque sentence is right: a database's own wording leaks
    /// schema and is no use to the person reading it. Saying nothing *server-side* is
    /// not. `ErrorLogging` deliberately lets an `HTTPError` past without a line,
    /// because a deliberate 401 or 409 is an answer rather than a fault — but the
    /// moment a database error is converted into one here, it stops being visible
    /// anywhere, and the only evidence left is a client reporting a blank failure.
    ///
    /// That has hidden three separate faults already: a refusal whose sentinel was
    /// never added to the switch, an argument bound as the wrong integer width so no
    /// function overload matched, and the collision this branch was last extended
    /// for. All three looked identical from outside and left nothing behind.
    private func unexplained(_ error: any Error) -> HTTPError {
        if let psql = error as? PSQLError {
            logger.error("unmapped database error", metadata: [
                "sqlstate": .string(psql.serverInfo?[.sqlState] ?? "none"),
                // The message is the sentinel that was never added to the switch, on
                // the day it turns out one is missing.
                "message": .string(psql.serverInfo?[.message] ?? "none"),
            ])
        } else {
            logger.error("unmapped error", metadata: [
                "error": .string(String(reflecting: error)),
            ])
        }
        return HTTPError(.internalServerError, message: "The request could not be completed.")
    }
}
