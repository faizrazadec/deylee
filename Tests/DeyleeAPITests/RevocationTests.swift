import Foundation
import Testing

@testable import DeyleeAPI

/// Revoking a session has to stop its access tokens, not only its refresh chain.
///
/// The gap this pins closed: `sid` was minted into every access token and read by
/// nothing, so `auth_revoke_session` ended the ninety-day chain while the token
/// already in someone's hands went on being honoured for the rest of its hour.
///
/// No database. The check lives in `TokenService` — deliberately, because three
/// routes verify a token and a guard added to two of them is a revocation with a
/// hole in it — and `TokenService` never opens a connection.
@Suite struct SessionRevocation {
    private func service(accessTokenTTL: Int = 3600) async throws -> TokenService {
        try await TokenService(config: try Config.load { key in
            [
                "GOOGLE_CLIENT_ID_IOS": "111-ios.apps.googleusercontent.com",
                "SESSION_JWT_PRIVATE_KEY_B64": Data(testPrivateKeyPEM.utf8).base64EncodedString(),
                "DEYLEE_DB_URL": "postgresql://unused.invalid/postgres",
                "RESEND_API_KEY": "re_placeholder",
                "RESEND_FROM": "Deylee <no-reply@revocation.invalid>",
                "RESEND_OTP_TEMPLATE_ID": "tmpl_placeholder",
                "ACCESS_TOKEN_TTL_SECONDS": "\(accessTokenTTL)",
            ][key]
        })
    }

    @Test("a revoked session's access token stops verifying")
    func revokedTokenIsRefused() async throws {
        let tokens = try await service()
        let user = UUID(), session = UUID()
        let access = try await tokens.issueAccessToken(userID: user, sessionID: session)

        let before = try await tokens.verifyAccessToken(access)
        #expect(before.sub.value == user.uuidString)

        await tokens.revoke(sessionID: session)

        await #expect(throws: (any Error).self) {
            _ = try await tokens.verifyAccessToken(access)
        }
    }

    @Test("revoking one session leaves the others alone")
    func otherSessionsSurvive() async throws {
        let tokens = try await service()
        let user = UUID()
        let kept = UUID()
        let keptToken = try await tokens.issueAccessToken(userID: user, sessionID: kept)

        // The password-change case: every session but this one ends.
        await tokens.revoke(sessionID: UUID())
        await tokens.revoke(sessionID: UUID())

        let payload = try await tokens.verifyAccessToken(keptToken)
        #expect(payload.sid == kept.uuidString, "the caller's own session was signed out")
    }

    /// An entry is only needed for as long as a token carrying that id could still be
    /// inside its expiry. Holding them forever would be a slow leak on a process that
    /// is meant to run for months.
    @Test("a revocation stops being remembered once its tokens have expired")
    func entriesExpire() async throws {
        let tokens = try await service(accessTokenTTL: 60)
        let session = UUID()
        let access = try await tokens.issueAccessToken(userID: UUID(), sessionID: session)

        let revokedAt = Date()
        await tokens.revoke(sessionID: session, now: revokedAt)

        // Still refused inside the window, on the token's own merits *and* the entry.
        await #expect(throws: (any Error).self) {
            _ = try await tokens.verifyAccessToken(access, now: revokedAt.addingTimeInterval(30))
        }

        // Past it, the entry is gone — and the only thing still refusing this token is
        // its expiry, which is the point: the set does not have to grow without bound.
        let stale = try await tokens.issueAccessToken(
            userID: UUID(), sessionID: session, now: revokedAt.addingTimeInterval(3600)
        )
        let payload = try await tokens.verifyAccessToken(
            stale, now: revokedAt.addingTimeInterval(3600)
        )
        #expect(payload.sid == session.uuidString)
    }
}
