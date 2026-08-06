import Foundation
import Testing

@testable import DeyleeAPI

/// Configuration is read once at boot and never again, so a mistake here is a
/// process that starts happily and is wrong for its whole lifetime. These pin the
/// refusals — the cases where refusing to start is the correct behaviour.

/// A minimal valid environment, as a dictionary so nothing touches the real one.
private func validEnv(_ overrides: [String: String] = [:]) -> [String: String] {
    var env: [String: String] = [
        "GOOGLE_CLIENT_ID_IOS": "111-ios.apps.googleusercontent.com",
        "SESSION_JWT_PRIVATE_KEY_B64": Data(testPrivateKeyPEM.utf8).base64EncodedString(),
        "DEYLEE_DB_URL": "postgresql://user:pw@localhost:5432/postgres",
    ]
    for (k, v) in overrides { env[k] = v }
    return env
}

private func load(_ env: [String: String]) throws -> Config {
    try Config.load { env[$0] }
}

/// A throwaway P-256 key, generated for this suite and used nowhere else.
/// Never paste a real signing key here: this file is committed, and a key in
/// git is a key that has to be rotated.
let testPrivateKeyPEM = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIC/YSqhru+TLD61OScLVoy6htoDsQryXDzXGXdjIUmcEoAoGCCqGSM49
    AwEHoUQDQgAEB41OA3jk+wltDCzDvu/PWYxze0h8gN+Q7Ep+9L0We2ZnEHF+HBLB
    vlOmJC+SQSE63eJsgexBvAyP3WpsriaSFw==
    -----END EC PRIVATE KEY-----
    """

@Suite struct ConfigLoading {
    @Test func loadsAMinimalValidEnvironment() throws {
        let config = try load(validEnv())
        #expect(config.googleAudiences == ["111-ios.apps.googleusercontent.com"])
        #expect(config.port == 8080)
        #expect(config.accessTokenTTL == 3600)
        #expect(config.refreshTokenTTL == 90 * 86_400)
        #expect(config.googleAllowedHostedDomain == nil)
    }

    /// Every configured client id is an accepted audience; the platforms that do
    /// not exist yet are blank and must not become one.
    @Test func collectsEveryConfiguredClientIdAndSkipsBlankOnes() throws {
        let config = try load(validEnv([
            "GOOGLE_CLIENT_ID_WEB": "222-web.apps.googleusercontent.com",
            "GOOGLE_CLIENT_ID_ANDROID": "",
            "GOOGLE_CLIENT_ID_DESKTOP": "   ",
        ]))
        #expect(config.googleAudiences.count == 2)
        #expect(config.googleAudiences.contains("222-web.apps.googleusercontent.com"))
        #expect(!config.googleAudiences.contains(""))
    }

    /// An empty audience set would mean every token is refused, which looks like a
    /// broken sign-in rather than a misconfiguration. Refuse to start instead.
    @Test func refusesToStartWithNoGoogleClientAtAll() {
        var env = validEnv()
        env.removeValue(forKey: "GOOGLE_CLIENT_ID_IOS")
        #expect(throws: ConfigError.self) { try load(env) }
    }

    @Test func refusesToStartWithoutASigningKey() {
        var env = validEnv()
        env.removeValue(forKey: "SESSION_JWT_PRIVATE_KEY_B64")
        #expect(throws: ConfigError.self) { try load(env) }
    }

    @Test func refusesToStartWithoutADatabase() {
        var env = validEnv()
        env.removeValue(forKey: "DEYLEE_DB_URL")
        #expect(throws: ConfigError.self) { try load(env) }
    }

    /// Pasting the PEM in directly rather than base64-encoding it is the obvious
    /// mistake, and it must not be mistaken for a key.
    @Test func rejectsASigningKeyThatIsNotBase64PEM() {
        #expect(throws: ConfigError.self) {
            try load(validEnv(["SESSION_JWT_PRIVATE_KEY_B64": testPrivateKeyPEM]))
        }
        #expect(throws: ConfigError.self) {
            try load(validEnv([
                "SESSION_JWT_PRIVATE_KEY_B64": Data("not a pem".utf8).base64EncodedString()
            ]))
        }
    }

    /// Google issues `iss` both with and without the scheme, and both are correct.
    /// Accepting only one rejects valid tokens seemingly at random.
    @Test func acceptsBothSpellingsOfGooglesIssuer() throws {
        let config = try load(validEnv())
        #expect(config.googleIssuers.contains("https://accounts.google.com"))
        #expect(config.googleIssuers.contains("accounts.google.com"))
    }

    @Test func carriesAHostedDomainRestrictionWhenSet() throws {
        let config = try load(validEnv(["GOOGLE_ALLOWED_HD": "snapdev.ai"]))
        #expect(config.googleAllowedHostedDomain == "snapdev.ai")
    }
}

@Suite struct DotEnvParsing {
    @Test func readsPairsAndIgnoresCommentsAndBlanks() throws {
        let path = NSTemporaryDirectory() + "/deylee-dotenv-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try """
            # a comment
            KEY_A=value-a

            KEY_B = value-b
            # KEY_C=commented-out
            URL=postgresql://u:p@host:5432/db?x=1
            """.write(toFile: path, atomically: true, encoding: .utf8)

        let env = DotEnv.read(at: path)
        #expect(env["KEY_A"] == "value-a")
        #expect(env["KEY_B"] == "value-b")
        #expect(env["KEY_C"] == nil)
        // A value containing '=' must survive intact; splitting on every '=' would
        // truncate exactly the connection strings this file exists to carry.
        #expect(env["URL"] == "postgresql://u:p@host:5432/db?x=1")
    }

    @Test func missingFileIsEmptyRatherThanFatal() {
        #expect(DotEnv.read(at: "/nonexistent/\(UUID().uuidString)").isEmpty)
    }
}

@Suite struct SessionTokens {
    private func service(_ overrides: [String: String] = [:]) async throws -> (TokenService, Config) {
        let config = try load(validEnv(overrides))
        return (try await TokenService(config: config), config)
    }

    @Test func issuesAnAccessTokenThatItCanVerify() async throws {
        let (tokens, _) = try await service()
        let user = UUID()
        let session = UUID()

        let jwt = try await tokens.issueAccessToken(userID: user, sessionID: session)
        let payload = try await tokens.verifyAccessToken(jwt)

        #expect(payload.sub.value == user.uuidString)
        #expect(payload.sid == session.uuidString)
        #expect(payload.iss.value == "https://api.deylee.app")
    }

    /// An expired token must be refused by the same call that accepts a live one —
    /// the check belongs in verification, not at the call sites.
    @Test func refusesAnExpiredAccessToken() async throws {
        let (tokens, _) = try await service(["ACCESS_TOKEN_TTL_SECONDS": "60"])
        let stale = try await tokens.issueAccessToken(
            userID: UUID(), sessionID: UUID(),
            now: Date().addingTimeInterval(-3600)
        )
        await #expect(throws: (any Error).self) {
            _ = try await tokens.verifyAccessToken(stale)
        }
    }

    /// A token signed by a different deployment must not be honoured here.
    @Test func refusesATokenFromAnotherIssuer() async throws {
        let (theirs, _) = try await service(["SESSION_JWT_ISSUER": "https://api.someone-else.example"])
        let (ours, _) = try await service()
        let foreign = try await theirs.issueAccessToken(userID: UUID(), sessionID: UUID())

        await #expect(throws: (any Error).self) {
            _ = try await ours.verifyAccessToken(foreign)
        }
    }
}

@Suite struct RefreshTokens {
    @Test func digestsToExactlyTheThirtyTwoBytesTheSchemaDemands() {
        // The refresh_tokens table constrains octet_length(token_hash) = 32; a
        // mismatch here would surface as a check violation at sign-in.
        #expect(RefreshToken.digest(RefreshToken.generate()).count == 32)
    }

    @Test func generatesADistinctTokenEachTime() {
        let tokens = (0..<64).map { _ in RefreshToken.generate() }
        #expect(Set(tokens).count == 64)
    }

    @Test func digestIsStableForTheSameToken() {
        let token = RefreshToken.generate()
        #expect(RefreshToken.digest(token) == RefreshToken.digest(token))
    }
}
