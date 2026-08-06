import AuthenticationServices
import CryptoKit
import DeyleeKit
import Foundation

/// Google sign-in, and the session that follows it.
///
/// The whole OAuth exchange happens here, in the app, and the API never sees a
/// Google credential — only the resulting ID token, once, which it verifies and
/// trades for a session of its own. That is what lets a native client work without
/// a client secret: PKCE proves the app that finished the exchange is the one that
/// started it, which a secret shipped inside a binary could never do.
@MainActor
final class AuthService: NSObject, ObservableObject {
    /// What the rest of the app is allowed to know about sign-in state.
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String, userID: String)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut

    private let config: ClientConfig
    private let repo: Repository
    private var session: StoredSession?
    private var webAuthSession: ASWebAuthenticationSession?

    init(config: ClientConfig, repo: Repository) {
        self.config = config
        self.repo = repo
        super.init()
        restore()
    }

    /// Reload a session left by a previous launch. Absent or unreadable is simply
    /// signed out — never a reason to fail to start.
    private func restore() {
        guard let stored = try? TokenStore.load() else { return }
        session = stored
        state = .signedIn(email: stored.email, userID: stored.userID)
    }

    // MARK: - Sign in

    func signIn() async {
        state = .signingIn
        do {
            let verifier = Self.makeCodeVerifier()
            let code = try await authorize(challenge: Self.challenge(for: verifier))
            let idToken = try await exchange(code: code, verifier: verifier)
            let session = try await establishSession(idToken: idToken)

            // Claim history written before anyone signed in. Everything local is
            // already dirty, so this is enough to carry all of it up on first sync.
            try repo.claimLocalData(forUserID: session.userID)

            try adopt(session)
        } catch let error as MutationError {
            // The "already belongs to another account" refusal, most likely.
            state = .failed(error.message)
        } catch is CancellationError {
            state = .signedOut
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            state = .signedOut
        } catch {
            state = .failed(Self.readable(error))
        }
    }

    /// Whether there is a session, without exposing it.
    var isSignedIn: Bool { session != nil }

    // MARK: - Email and password

    func signUp(email: String, password: String) async {
        await withPassword(path: "/v1/auth/signup", email: email, password: password)
    }

    func signInWithPassword(email: String, password: String) async {
        await withPassword(path: "/v1/auth/password", email: email, password: password)
    }

    private func withPassword(path: String, email: String, password: String) async {
        state = .signingIn
        struct Body: Encodable {
            let email: String
            let password: String
            let deviceId: String?
            let timezone: String
        }
        do {
            let response: SessionResponseDTO = try await APIClient.post(
                config.apiBaseURL.appending(path: path),
                body: Body(
                    email: email,
                    password: password,
                    deviceId: try? repo.syncState().deviceID,
                    timezone: TimeZone.current.identifier
                )
            )
            try adopt(response.stored())
        } catch let error as MutationError {
            state = .failed(error.message)
        } catch {
            state = .failed(Self.readable(error))
        }
    }

    /// Take a freshly issued session: claim any history written before it existed,
    /// store it, and announce it.
    ///
    /// Claiming comes first deliberately. If the store already belongs to somebody
    /// else it throws here, before the session is written — otherwise the app would
    /// be signed in as one person while holding another person's hours.
    private func adopt(_ session: StoredSession) throws {
        try repo.claimLocalData(forUserID: session.userID)
        try TokenStore.save(session)
        self.session = session
        state = .signedIn(email: session.email, userID: session.userID)
    }

    /// A sentence rather than a type name.
    ///
    /// This text is shown under the field on the sign-in screen, so
    /// `URLError(.cannotConnectToHost)` would be a poor thing to hand somebody who
    /// simply has no network — and "could not connect" is also what the window
    /// looks for before offering to work without an account.
    private static func readable(_ error: any Error) -> String {
        if let failure = error as? APIClient.HTTPFailure { return failure.message }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You appear to be offline — could not connect to Deylee."
            case .cannotConnectToHost, .cannotFindHost, .timedOut:
                return "Could not connect to Deylee. It may be down, or you may be offline."
            default:
                return url.localizedDescription
            }
        }
        return String(describing: error)
    }

    /// Sign out locally.
    ///
    /// Deliberately does *not* delete the local store. The hours belong to the
    /// person who tracked them, and signing out of a sync service is not a request
    /// to destroy them.
    func signOut() {
        TokenStore.clear()
        session = nil
        state = .signedOut
    }

    // MARK: - Tokens

    /// A usable access token, refreshing if the one held has expired.
    ///
    /// Returns nil when signed out or when the refresh token itself has expired, in
    /// which case the only remedy is signing in again.
    func accessToken(now: EpochMs = EpochMs(Date().timeIntervalSince1970 * 1000)) async -> String? {
        guard let current = session else { return nil }
        if current.isAccessTokenUsable(at: now) { return current.accessToken }

        do {
            let renewed = try await refresh(current)
            try TokenStore.save(renewed)
            session = renewed
            return renewed.accessToken
        } catch {
            // The refresh token was rejected — expired, revoked, or replayed and the
            // whole chain revoked with it. Signing out is the honest outcome; leaving
            // a session that cannot renew produces a 401 on every sync forever.
            signOut()
            return nil
        }
    }

    private func refresh(_ current: StoredSession) async throws -> StoredSession {
        struct Body: Encodable { let refreshToken: String }
        let response: SessionResponseDTO = try await APIClient.post(
            config.apiBaseURL.appending(path: "/v1/auth/refresh"),
            body: Body(refreshToken: current.refreshToken)
        )
        return response.stored()
    }

    // MARK: - OAuth

    /// Open Google's consent screen and return the authorization code.
    private func authorize(challenge: String) async throws -> String {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: config.googleClientID),
            .init(name: "redirect_uri", value: config.googleRedirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: config.googleCallbackScheme
            ) { @Sendable url, error in
                // `@Sendable` is load-bearing, not decoration.
                //
                // ASWebAuthenticationSession delivers its result over XPC, on a
                // background queue. Without this marker the closure inherits this
                // method's @MainActor isolation, and Swift 6 emits a runtime executor
                // check that fails there — dispatch_assert_queue_fail, SIGTRAP, the
                // app disappearing at the exact moment sign-in succeeds. It compiles
                // cleanly either way, which is what makes it worth a comment.
                //
                // Resuming a continuation is safe from any thread, so nothing else
                // needs to hop.
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: CancellationError()) }
            }
            session.presentationContextProvider = self
            // Reuses the system browser's existing session, so signing in once is
            // remembered rather than retyped on every launch.
            session.prefersEphemeralWebBrowserSession = false
            // Held for the duration: a session released mid-flow takes the sheet with
            // it, and the continuation would never be resumed.
            self.webAuthSession = session
            session.start()
        }
        webAuthSession = nil

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw AuthError.noAuthorizationCode
        }
        return code
    }

    /// Trade the code for an ID token, directly with Google.
    private func exchange(code: String, verifier: String) async throws -> String {
        struct TokenResponse: Decodable { let id_token: String }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: config.googleClientID),
            .init(name: "redirect_uri", value: config.googleRedirectURI),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.googleRejectedTheExchange(
                String(data: data, encoding: .utf8) ?? "no detail"
            )
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data).id_token
    }

    /// Hand the ID token to our API and take back a session of ours.
    private func establishSession(idToken: String) async throws -> StoredSession {
        struct Body: Encodable {
            let idToken: String
            let deviceId: String?
            let timezone: String
        }
        let deviceID = try? repo.syncState().deviceID
        let response: SessionResponseDTO = try await APIClient.post(
            config.apiBaseURL.appending(path: "/v1/auth/google"),
            body: Body(
                idToken: idToken,
                deviceId: deviceID,
                // The server needs this to attribute a day correctly for anyone
                // whose day does not start when the server's does.
                timezone: TimeZone.current.identifier
            )
        )
        return response.stored()
    }

    // MARK: - PKCE

    /// 32 random bytes, base64url without padding — comfortably inside RFC 7636's
    /// 43-to-128-character window.
    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum AuthError: Error, CustomStringConvertible {
    case noAuthorizationCode
    case googleRejectedTheExchange(String)

    var description: String {
        switch self {
        case .noAuthorizationCode:
            "Google did not return an authorization code."
        case .googleRejectedTheExchange(let detail):
            "Google refused the token exchange: \(detail)"
        }
    }
}

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // A menu-bar app often has no window at all, so one is conjured rather than
        // assumed. Returning a detached window is valid and keeps the sheet anchored
        // to the app rather than to whatever happens to be frontmost.
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        }
    }
}

/// The API's session response, as it arrives.
struct SessionResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: User

    struct User: Decodable {
        let id: String
        let email: String
        let displayName: String?
        let timezone: String
    }

    func stored(now: Date = Date()) -> StoredSession {
        StoredSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessExpiresAt: EpochMs(now.timeIntervalSince1970 * 1000) + EpochMs(expiresIn) * 1000,
            userID: user.id,
            email: user.email,
            displayName: user.displayName
        )
    }
}
