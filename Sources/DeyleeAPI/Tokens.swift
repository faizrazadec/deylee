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

    enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, email, name, hd
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
    func verifyGoogleIDToken(_ token: String) async throws -> GoogleIDToken {
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

    func verifyAccessToken(_ token: String) async throws -> SessionToken {
        let payload = try await sessionKeys.verify(token, as: SessionToken.self)
        guard payload.iss.value == config.sessionIssuer else {
            throw TokenError.issuerRejected(payload.iss.value)
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
