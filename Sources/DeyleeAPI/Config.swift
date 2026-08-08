import Foundation

/// Everything the API needs from its environment, read once at boot.
///
/// Read once and passed around rather than looked up at each use, so a missing
/// variable stops the process on the first line of `main` instead of failing the
/// first request that happens to need it — quite possibly in production, hours
/// later, on a code path nobody exercised.
struct Config: Sendable {
    /// Google OAuth client ids we will accept an ID token from.
    ///
    /// Google stamps a different `aud` on each platform's client. Accepting the
    /// whole set rather than a single value is what lets one API serve the Mac app
    /// and the web dashboard; accepting *anything* would let a token minted for
    /// somebody else's Google project through.
    let googleAudiences: Set<String>
    let googleIssuers: Set<String>
    let googleJWKSURL: URL

    /// Restrict sign-in to one Google Workspace domain, by the `hd` claim. Nil
    /// accepts any Google account, including personal ones, which carry no `hd`.
    let googleAllowedHostedDomain: String?

    /// PEM of the P-256 key this API signs its own access tokens with.
    let sessionPrivateKeyPEM: String
    let sessionIssuer: String
    let accessTokenTTL: TimeInterval
    let refreshTokenTTL: TimeInterval

    /// The restricted login. Not the migration credential: this one is subject to
    /// row-level security, which is the entire reason it exists.
    let databaseURL: String

    /// Whether to encrypt the database connection at all.
    ///
    /// Defaults to requiring it. A development database in a container on a private
    /// network offers no TLS, and this used to be inferred from the hostname being
    /// `localhost` — which is wrong the moment that database is a container reached
    /// by name, the ordinary way to run one.
    let databaseTLS: Bool

    /// PEM of the CA that signed the database server's certificate.
    ///
    /// Supabase signs with its own CA rather than a publicly-trusted one, so
    /// without this the connection is encrypted but the server is unauthenticated.
    /// Downloadable from Settings -> Database in the dashboard.
    let databaseCACertificatePath: String?

    /// Resend, which carries the sign-up code.
    ///
    /// Required rather than optional, deliberately. Sign-up cannot complete without
    /// mail, so a deployment missing these is broken — and it is far better to learn
    /// that on the first line of `main` than from the first person who tries to make
    /// an account and never receives anything.
    let resendAPIKey: String
    /// The `From` header, e.g. `Deylee <no-reply@deylee.app>`. The domain has to be
    /// verified in Resend or every send is refused.
    let resendFrom: String
    /// Id or alias of the published template. It takes one variable, `otp`.
    let resendOTPTemplateID: String

    /// How long a sign-up code stays good.
    let signupCodeTTL: Int
    /// How long before another code may be sent to the same address. Without it the
    /// endpoint is a free way to post mail to a stranger's inbox.
    let signupCodeResendCooldown: Int

    let port: Int

    /// The address to bind.
    ///
    /// Loopback by default, so a development run is not quietly serving the whole
    /// local network. A container must set HOST=0.0.0.0 or nothing outside it can
    /// reach the process — the platform's health check fails, the deploy is marked
    /// bad, and the logs say only that the server started.
    let host: String
}

enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    case malformed(String, reason: String)

    var description: String {
        switch self {
        case .missing(let key):
            "\(key) is not set. Copy .env.example to .env and fill it in."
        case .malformed(let key, let reason):
            "\(key) is malformed: \(reason)"
        }
    }
}

extension Config {
    /// Build from a variable lookup, defaulting to the process environment.
    ///
    /// The lookup is a parameter so tests can supply a dictionary instead of
    /// mutating the environment of the process running them.
    static func load(_ lookup: (String) -> String? = { ProcessInfo.processInfo.environment[$0] })
        throws -> Config
    {
        // Both trim. A value copied out of a dashboard often arrives with a
        // trailing space or newline attached, and an untrimmed client id is worse
        // than a missing one: it looks configured, passes every startup check, and
        // then silently matches no token Google will ever issue.
        func optional(_ key: String) -> String? {
            guard let v = lookup(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty
            else { return nil }
            return v
        }
        func required(_ key: String) throws -> String {
            guard let v = optional(key) else { throw ConfigError.missing(key) }
            return v
        }

        // Every client id that is actually configured becomes an accepted audience.
        // Empty ones are platforms that do not exist yet, and an empty string must
        // never end up in the set — it would match a token with no `aud` at all.
        let audiences = [
            "GOOGLE_CLIENT_ID_IOS", "GOOGLE_CLIENT_ID_WEB",
            "GOOGLE_CLIENT_ID_ANDROID", "GOOGLE_CLIENT_ID_DESKTOP",
        ].compactMap(optional)

        guard !audiences.isEmpty else {
            throw ConfigError.missing("GOOGLE_CLIENT_ID_* (at least one)")
        }

        let jwksString = optional("GOOGLE_JWKS_URL") ?? "https://www.googleapis.com/oauth2/v3/certs"
        guard let jwksURL = URL(string: jwksString) else {
            throw ConfigError.malformed("GOOGLE_JWKS_URL", reason: "not a URL")
        }

        let pem = try decodeBase64PEM(required("SESSION_JWT_PRIVATE_KEY_B64"),
                                      key: "SESSION_JWT_PRIVATE_KEY_B64")

        // Google is inconsistent about the scheme in the `iss` claim it issues, and
        // both spellings are legitimate. A verifier that knows only one rejects
        // perfectly valid tokens, seemingly at random.
        let issuer = optional("GOOGLE_ISSUER") ?? "https://accounts.google.com"
        let issuers: Set<String> = [issuer, issuer.replacingOccurrences(of: "https://", with: "")]

        return Config(
            googleAudiences: Set(audiences),
            googleIssuers: issuers,
            googleJWKSURL: jwksURL,
            googleAllowedHostedDomain: optional("GOOGLE_ALLOWED_HD"),
            sessionPrivateKeyPEM: pem,
            sessionIssuer: optional("SESSION_JWT_ISSUER") ?? "https://api.deylee.app",
            accessTokenTTL: TimeInterval(optional("ACCESS_TOKEN_TTL_SECONDS").flatMap(Int.init) ?? 3600),
            refreshTokenTTL: TimeInterval(optional("REFRESH_TOKEN_TTL_DAYS").flatMap(Int.init) ?? 90) * 86_400,
            databaseURL: try required("DEYLEE_DB_URL"),
            databaseTLS: (optional("DEYLEE_DB_TLS") ?? "require").lowercased() != "disable",
            databaseCACertificatePath: optional("DEYLEE_DB_CA_CERT"),
            resendAPIKey: try required("RESEND_API_KEY"),
            resendFrom: try required("RESEND_FROM"),
            resendOTPTemplateID: try required("RESEND_OTP_TEMPLATE_ID"),
            // Ten minutes is long enough to find the mail in a spam folder and short
            // enough that a code left on a screen is not a standing key.
            signupCodeTTL: optional("SIGNUP_CODE_TTL_SECONDS").flatMap(Int.init) ?? 600,
            signupCodeResendCooldown:
                optional("SIGNUP_CODE_RESEND_SECONDS").flatMap(Int.init) ?? 60,
            port: optional("PORT").flatMap(Int.init) ?? 8080,
            host: optional("HOST") ?? "127.0.0.1"
        )
    }

    private static func decodeBase64PEM(_ encoded: String, key: String) throws -> String {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let pem = String(data: data, encoding: .utf8)
        else {
            throw ConfigError.malformed(key, reason: "not base64-encoded UTF-8")
        }
        guard pem.contains("-----BEGIN") else {
            throw ConfigError.malformed(key, reason: "decoded value is not PEM")
        }
        return pem
    }
}

/// Load `.env` into a dictionary, for local runs.
///
/// Deliberately not applied to the process environment: a real deployment injects
/// variables itself, and a file quietly overriding those would be the kind of bug
/// that only shows up once, in production, at the worst moment.
enum DotEnv {
    static func read(at path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=")
            else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out
    }

    /// The process environment wins over the file, never the other way round.
    static func merged(with path: String) -> (String) -> String? {
        let file = read(at: path)
        return { key in
            if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
            return file[key]
        }
    }
}
