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
    let logger: Logger

    func addRoutes(to router: Router<BasicRequestContext>) {
        router.post("/v1/auth/google", use: signInWithGoogle)
        router.post("/v1/auth/signup", use: signUpWithPassword)
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

    @Sendable
    func signUpWithPassword(
        _ request: Request, context: BasicRequestContext
    ) async throws -> SessionResponse {
        let body = try await request.decode(as: PasswordRequest.self, context: context)
        let user = try await callReturningUser(
            """
            SELECT id, email, display_name, timezone
            FROM public.auth_sign_up_with_password(
                \(body.email), \(body.password), \(body.displayName), \(body.timezone))
            """
        )
        return try await issueSession(for: user, deviceID: body.deviceId)
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
            throw Self.mapped(error)
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
            throw Self.mapped(error)
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
    private static func mapped(_ error: any Error) -> HTTPError {
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
        case "unverified-email":
            return HTTPError(.unauthorized, message: "Google has not verified that address.")
        case "invalid-credentials":
            return HTTPError(.unauthorized, message: "That email and password do not match.")
        case "no-such-user":
            return HTTPError(.unauthorized, message: "That account no longer exists.")
        default:
            return HTTPError(.internalServerError, message: "The request could not be completed.")
        }
    }
}
