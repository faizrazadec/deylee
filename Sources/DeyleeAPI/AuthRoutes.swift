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

// MARK: - Routes

struct AuthController: Sendable {
    let store: Store
    let tokens: TokenService
    let config: Config
    let logger: Logger

    func addRoutes(to router: Router<BasicRequestContext>) {
        router.post("/v1/auth/google", use: signInWithGoogle)
        router.post("/v1/auth/refresh", use: refresh)
    }

    /// Exchange a Google ID token for a session of our own.
    ///
    /// Runs without tenancy: there is no user id to scope to until Google has been
    /// believed, and `app_users` is not reachable from a user-scoped connection.
    @Sendable
    func signInWithGoogle(
        _ request: Request, context: BasicRequestContext
    ) async throws -> SessionResponse {
        let body = try await request.decode(as: GoogleSignInRequest.self, context: context)

        let claims: GoogleIDToken
        do {
            claims = try await tokens.verifyGoogleIDToken(body.idToken)
        } catch let error as TokenError {
            // The reason is safe to return: it tells a legitimate user why they were
            // refused — wrong account, unverified address — and tells an attacker
            // only that their forged token was rejected.
            throw HTTPError(.unauthorized, message: error.description)
        }

        guard let email = claims.email else {
            throw HTTPError(.unauthorized, message: "Google returned no email address.")
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sessionID = UUID()
        let refreshToken = RefreshToken.generate()
        let refreshExpiry = now + Int64(config.refreshTokenTTL * 1000)

        let user = try await store.withoutTenant { connection in
            // Keyed on the Google subject, never the email: people change their
            // address, and matching on it would eventually attach one person's
            // history to another person's account.
            let rows = try await connection.query(
                """
                INSERT INTO public.app_users
                    (google_sub, email, email_verified, display_name, timezone)
                VALUES (\(claims.sub.value), \(email), \(claims.emailVerified ?? false),
                        \(claims.name), COALESCE(\(body.timezone), 'UTC'))
                ON CONFLICT (google_sub) DO UPDATE SET
                    email          = EXCLUDED.email,
                    email_verified = EXCLUDED.email_verified,
                    display_name   = COALESCE(EXCLUDED.display_name, app_users.display_name),
                    timezone       = COALESCE(\(body.timezone), app_users.timezone),
                    updated_at     = \(now),
                    last_seen_at   = \(now)
                RETURNING id, email, display_name, timezone
                """,
                logger: logger
            )

            var found: UserDTO?
            for try await (id, mail, name, zone) in rows.decode(
                (UUID, String, String?, String).self
            ) {
                found = UserDTO(id: id.uuidString, email: mail, displayName: name, timezone: zone)
            }
            guard let user = found else {
                throw HTTPError(.internalServerError, message: "The account could not be stored.")
            }

            _ = try await connection.query(
                """
                INSERT INTO public.refresh_tokens
                    (user_id, session_id, token_hash, device_id, issued_at, expires_at)
                VALUES (\(UUID(uuidString: user.id)!), \(sessionID),
                        \(ByteBuffer(bytes: RefreshToken.digest(refreshToken))), \(body.deviceId),
                        \(now), \(refreshExpiry))
                """,
                logger: logger
            )
            return user
        }

        let access = try await tokens.issueAccessToken(
            userID: UUID(uuidString: user.id)!, sessionID: sessionID
        )

        logger.info("signed in", metadata: ["user": .string(user.id)])

        return SessionResponse(
            accessToken: access,
            refreshToken: refreshToken,
            expiresIn: Int(config.accessTokenTTL),
            user: user
        )
    }

    /// Trade a refresh token for a new pair, rotating it.
    ///
    /// Rotation is what makes theft survivable. Each refresh mints a new token and
    /// marks the old one replaced; presenting a token that has already been
    /// replaced means two parties hold it, and the only safe reading is that one of
    /// them stole it. Both are then signed out — the legitimate user included,
    /// which is the point, because otherwise nobody ever finds out.
    @Sendable
    func refresh(_ request: Request, context: BasicRequestContext) async throws -> SessionResponse {
        let body = try await request.decode(as: RefreshRequest.self, context: context)
        let digest = ByteBuffer(bytes: RefreshToken.digest(body.refreshToken))
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let newToken = RefreshToken.generate()
        let newExpiry = now + Int64(config.refreshTokenTTL * 1000)

        let (user, sessionID) = try await store.withoutTenant { connection -> (UserDTO, UUID) in
            let rows = try await connection.query(
                """
                SELECT t.id, t.user_id, t.session_id, t.expires_at, t.revoked_at, t.replaced_by,
                       u.email, u.display_name, u.timezone
                FROM public.refresh_tokens t
                JOIN public.app_users u ON u.id = t.user_id
                WHERE t.token_hash = \(digest)
                """,
                logger: logger
            )

            var row: (UUID, UUID, UUID, Int64, Int64?, UUID?, String, String?, String)?
            for try await found in rows.decode(
                (UUID, UUID, UUID, Int64, Int64?, UUID?, String, String?, String).self
            ) {
                row = found
            }

            guard let (tokenID, userID, sessionID, expiresAt, revokedAt, replacedBy,
                       email, displayName, timezone) = row
            else {
                throw HTTPError(.unauthorized, message: "That refresh token is not recognised.")
            }

            // Replay. Revoke the entire chain, not just the row presented.
            if revokedAt != nil || replacedBy != nil {
                _ = try await connection.query(
                    """
                    UPDATE public.refresh_tokens SET revoked_at = \(now)
                    WHERE session_id = \(sessionID) AND revoked_at IS NULL
                    """,
                    logger: logger
                )
                logger.warning("refresh token replayed; session revoked", metadata: [
                    "user": .string(userID.uuidString), "session": .string(sessionID.uuidString),
                ])
                throw HTTPError(.unauthorized, message: "That session has been ended. Sign in again.")
            }

            guard expiresAt > now else {
                throw HTTPError(.unauthorized, message: "That refresh token has expired.")
            }

            let inserted = try await connection.query(
                """
                INSERT INTO public.refresh_tokens
                    (user_id, session_id, token_hash, issued_at, expires_at)
                VALUES (\(userID), \(sessionID), \(ByteBuffer(bytes: RefreshToken.digest(newToken))),
                        \(now), \(newExpiry))
                RETURNING id
                """,
                logger: logger
            )
            var newID: UUID?
            for try await id in inserted.decode(UUID.self) { newID = id }
            guard let newID else {
                throw HTTPError(.internalServerError, message: "The session could not be renewed.")
            }

            _ = try await connection.query(
                "UPDATE public.refresh_tokens SET replaced_by = \(newID) WHERE id = \(tokenID)",
                logger: logger
            )

            return (
                UserDTO(id: userID.uuidString, email: email,
                        displayName: displayName, timezone: timezone),
                sessionID
            )
        }

        let access = try await tokens.issueAccessToken(
            userID: UUID(uuidString: user.id)!, sessionID: sessionID
        )

        return SessionResponse(
            accessToken: access,
            refreshToken: newToken,
            expiresIn: Int(config.accessTokenTTL),
            user: user
        )
    }
}
