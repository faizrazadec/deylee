import Crypto
import Foundation
import JWTKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Two different algorithms are in play and conflating them is a real bug, not a
// technicality. Google signs ID tokens with RS256 against rotating RSA keys it
// publishes. This API signs its own access tokens with ES256 against a P-256 key
// it holds. A verifier written for one silently rejects the other.

/// The subset of Google's ID token claims that matter here.
struct GoogleIDToken: JWTPayload {
    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let email: String?
    let emailVerified: Bool?
    let name: String?
    /// Present only for Google Workspace accounts. A personal gmail.com account
    /// has none, which is why a hosted-domain check must treat nil as "no domain"
    /// rather than as a value to compare.
    let hd: String?
    /// Echoed back from the authorization request. Absent on a token minted for a
    /// request that never sent one — which, now that the client always does, means the
    /// token was not minted for this sign-in.
    let nonce: String?

    enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, email, name, hd, nonce
        case emailVerified = "email_verified"
    }

    /// Expiry only. Audience, issuer and hosted domain are checked in
    /// ``TokenService/verifyGoogleIDToken(_:)`` against configuration this type has
    /// no access to — and checking them in one place makes it impossible to verify
    /// a token while forgetting one of them.
    func verify(using _: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }
}

/// The access token this API issues and verifies.
struct SessionToken: JWTPayload {
    let sub: SubjectClaim
    let iss: IssuerClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    /// The refresh chain this access token belongs to. Carried so a revoked chain
    /// can be recognised without a database round trip on every request.
    let sid: String

    func verify(using _: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }
}

enum TokenError: Error, CustomStringConvertible, Equatable {
    case audienceRejected
    case issuerRejected(String)
    case emailUnverified
    case hostedDomainRejected(String?)
    case jwksUnavailable
    case nonceMismatch
    case invalid(String)

    var description: String {
        switch self {
        case .audienceRejected:
            "The token was issued for a different application."
        case .issuerRejected(let got):
            "The token was issued by \(got), which is not Google."
        case .emailUnverified:
            "Google has not verified that email address."
        case .hostedDomainRejected(let got):
            "Sign-in is restricted to one Workspace domain; this account is in \(got ?? "none")."
        case .jwksUnavailable:
            "Google's signing keys could not be fetched."
        case .nonceMismatch:
            "That token was not issued for this sign-in."
        case .invalid(let why):
            "The token is not valid: \(why)"
        }
    }
}

/// Verifies Google's ID tokens and mints this API's own.
///
/// An actor because the cached Google key set is mutable shared state: several
/// requests can discover an unknown key id at the same moment, and without
/// serialisation they would each trigger their own refetch.
actor TokenService {
    private let config: Config
    private let googleKeys = JWTKeyCollection()
    private let sessionKeys = JWTKeyCollection()
    private let fetch: @Sendable (URL) async throws -> Data

    private var googleKeysLoadedAt: Date?

    /// Session ids whose access tokens have stopped counting, each with the moment it
    /// stops mattering.
    ///
    /// Revoking a session revokes its refresh chain, and until this existed that was
    /// the whole of it: the access token already in the thief's hands stayed valid for
    /// the rest of its hour, so signing out did nothing a stolen session could feel.
    /// An entry only has to outlive the longest-lived token carrying that id, which is
    /// one access-token lifetime from the moment of revocation — after that every such
    /// token fails on expiry alone.
    ///
    /// ponytail: one process's memory. A second replica keeps its own set and would
    /// honour a token this one refuses; the upgrade is a shared cache, or reading
    /// `refresh_tokens.revoked_at` per request if the round trip is ever affordable.
    private var revokedSessions: [String: Date] = [:]

    /// Floor between refetches of Google's key set.
    ///
    /// An unknown `kid` triggers a refresh, and an unknown `kid` is something an
    /// attacker can produce at will by signing garbage. Without a floor, that is a
    /// free amplified request to Google on every forged token.
    private static let minimumRefreshInterval: TimeInterval = 300

    init(
        config: Config,
        fetch: @escaping @Sendable (URL) async throws -> Data = { url in
            try await URLSession.shared.data(from: url).0
        }
    ) async throws {
        self.config = config
        self.fetch = fetch
        await sessionKeys.add(ecdsa: try ES256PrivateKey(pem: config.sessionPrivateKeyPEM))
    }

    // MARK: - Google

    /// Verify a Google ID token and return its claims, or explain the refusal.
    ///
    /// - Parameter nonce: the value the client put in its authorization request. The
    ///   token must echo it. Without this check, an ID token obtained anywhere else
    ///   for the same `aud` is indistinguishable from one minted for this sign-in.
    ///
    ///   Not optional, deliberately. A nonce the caller may leave out is one an
    ///   attacker leaves out — the body is theirs to write — and the check would then
    ///   protect only the clients that were never the threat.
    func verifyGoogleIDToken(_ token: String, nonce: String) async throws -> GoogleIDToken {
        try await ensureGoogleKeys()

        let payload: GoogleIDToken
        do {
            payload = try await googleKeys.verify(token, as: GoogleIDToken.self)
        } catch {
            // Most likely a key rotation: Google published a new one after our last
            // fetch. Refresh once and retry before calling the token invalid.
            guard await refreshGoogleKeysIfAllowed() else {
                throw TokenError.invalid(String(describing: error))
            }
            payload = try await googleKeys.verify(token, as: GoogleIDToken.self)
        }

        guard config.googleIssuers.contains(payload.iss.value) else {
            throw TokenError.issuerRejected(payload.iss.value)
        }

        // `aud` identifies which of our OAuth clients the token was minted for. A
        // token for someone else's Google project is a perfectly valid Google token
        // and must still be refused, which is why this is an explicit set.
        guard payload.aud.value.contains(where: { config.googleAudiences.contains($0) }) else {
            throw TokenError.audienceRejected
        }

        // An unverified address must not identify anybody: on some providers it can
        // be claimed without ever proving control of the mailbox.
        guard payload.emailVerified == true else { throw TokenError.emailUnverified }

        // Checked here with the rest, per this function's own reason for existing: a
        // token verified in one place while one of its checks is forgotten in another
        // is the failure the single call site prevents.
        //
        guard payload.nonce == nonce else { throw TokenError.nonceMismatch }

        if let required = config.googleAllowedHostedDomain {
            guard payload.hd == required else {
                throw TokenError.hostedDomainRejected(payload.hd)
            }
        }

        return payload
    }

    private func ensureGoogleKeys() async throws {
        guard googleKeysLoadedAt == nil else { return }
        guard await refreshGoogleKeysIfAllowed(force: true) else {
            throw TokenError.jwksUnavailable
        }
    }

    @discardableResult
    private func refreshGoogleKeysIfAllowed(force: Bool = false) async -> Bool {
        if !force, let loaded = googleKeysLoadedAt,
           Date().timeIntervalSince(loaded) < Self.minimumRefreshInterval {
            return false
        }
        do {
            let data = try await fetch(config.googleJWKSURL)
            let jwks = try JSONDecoder().decode(JWKS.self, from: data)
            try await googleKeys.add(jwks: jwks)
            googleKeysLoadedAt = Date()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Our own sessions

    func issueAccessToken(userID: UUID, sessionID: UUID, now: Date = Date()) async throws -> String {
        try await sessionKeys.sign(
            SessionToken(
                sub: .init(value: userID.uuidString),
                iss: .init(value: config.sessionIssuer),
                exp: .init(value: now.addingTimeInterval(config.accessTokenTTL)),
                iat: .init(value: now),
                sid: sessionID.uuidString
            )
        )
    }

    /// Stop honouring access tokens on this session.
    ///
    /// Called beside every database revocation rather than instead of it. The database
    /// is what makes a revocation survive a restart; this is what makes it take effect
    /// before the hour is out.
    func revoke(sessionID: UUID, now: Date = Date()) {
        revokedSessions[sessionID.uuidString] = now.addingTimeInterval(config.accessTokenTTL)
        // Swept here because this is the only thing that makes the map grow, and it is
        // rare — a sign-out, a password change, a replayed token.
        revokedSessions = revokedSessions.filter { $0.value > now }
    }

    func verifyAccessToken(_ token: String, now: Date = Date()) async throws -> SessionToken {
        let payload = try await sessionKeys.verify(token, as: SessionToken.self)
        guard payload.iss.value == config.sessionIssuer else {
            throw TokenError.issuerRejected(payload.iss.value)
        }
        // Checked here rather than in the routes: three of them verify a token, and a
        // guard added to two of the three is a revocation that works everywhere except
        // the one place somebody forgot.
        if let until = revokedSessions[payload.sid], until > now {
            throw TokenError.invalid("that session has been signed out")
        }
        return payload
    }
}

/// A refresh token: high-entropy, opaque, and stored only as a digest.
///
/// Opaque rather than a JWT on purpose. A JWT is self-describing and valid until
/// it expires, which is the opposite of what a refresh token needs — the whole
/// point is that presenting one can be refused because of state on the server.
enum RefreshToken {
    /// 256 bits from the system CSPRNG. `SymmetricKey` rather than a loop over
    /// `UInt8.random`, because this value is a credential and its unguessability is
    /// the only thing protecting a ninety-day session.
    static func generate() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// SHA-256, matching the `octet_length(token_hash) = 32` constraint on the
    /// table. Only this ever reaches the database.
    static func digest(_ token: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(token.utf8)))
    }
}
