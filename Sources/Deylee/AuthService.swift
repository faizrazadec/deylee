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
        /// A code has been mailed and is waiting to be typed back. No account exists
        /// yet — it is built from the parked request when the code checks out.
        case awaitingCode(email: String)
        /// Signed in as far as the server is concerned, but this machine's history
        /// belongs to somebody else and nothing has been written yet. Waiting on
        /// `confirmTransfer()` or `cancelTransfer()`.
        case needsTransferConfirmation(email: String)
        case signedIn(email: String, userID: String)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut

    /// A rejected code, shown under the code field.
    ///
    /// Kept apart from `.failed` on purpose. Moving to `.failed` would take the code
    /// screen off the display and drop the person back at the form, having to start
    /// the whole sign-up again because they mistyped one digit.
    @Published private(set) var codeError: String?

    /// When another code may be asked for. The server owns the cooldown; this is only
    /// what the countdown is drawn from.
    @Published private(set) var resendAvailableAt: Date?

    private let config: ClientConfig
    private let repo: Repository
    private var session: StoredSession?
    /// A session issued but not yet written, held only while the transfer question
    /// is on screen. Never reaches the keychain unless the answer is yes.
    private var pendingTransfer: StoredSession?
    /// The sign-up waiting on a code. Held in memory only, for the length of one
    /// screen, because a resend has to send the same credentials again — the server
    /// stores a digest and cannot reconstruct them. Dropped on success or cancel,
    /// and never written to disk.
    private var pendingSignup: (email: String, password: String)?
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

            // `adopt` claims history written before anyone signed in — everything
            // local is already dirty, so recording the user carries all of it up on
            // the first sync — and parks the session instead if the store turns out
            // to belong to somebody else.
            try adopt(session)
        } catch let error as MutationError {
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

    /// Step one of sign-up: ask the server to mail a code.
    ///
    /// Nothing exists as an account when this returns. The address and password are
    /// parked on the server until the code comes back, which is what stops anybody
    /// registering a mailbox they do not own.
    func signUp(email: String, password: String) async {
        state = .signingIn
        codeError = nil
        guard await requestCode(email: email, password: password) else { return }
        // Held for a resend, which has to send the same credentials again. Cleared
        // the moment the code is accepted or the screen is abandoned.
        pendingSignup = (email: email, password: password)
        state = .awaitingCode(email: email)
    }

    /// Step two: hand the code back and take the session it produces.
    func verifyCode(_ code: String) async {
        guard case .awaitingCode(let email) = state else { return }
        codeError = nil
        struct Body: Encodable {
            let email: String
            let code: String
            let deviceId: String?
            let timezone: String
        }
        do {
            let response: SessionResponseDTO = try await APIClient.post(
                config.apiBaseURL.appending(path: "/v1/auth/signup/verify"),
                body: Body(
                    email: email,
                    code: code.trimmingCharacters(in: .whitespaces),
                    deviceId: try? repo.syncState().deviceID,
                    timezone: TimeZone.current.identifier
                )
            )
            pendingSignup = nil
            resendAvailableAt = nil
            try adopt(response.stored(provider: "Email"))
        } catch let error as MutationError {
            codeError = error.message
        } catch {
            // Stays on the code screen: a wrong digit is not a reason to throw away
            // a code that is still good for another try.
            codeError = Self.readable(error)
        }
    }

    /// Ask for another code. The server enforces the cooldown; this only avoids
    /// spending a request it is certain to refuse.
    func resendCode() async {
        guard case .awaitingCode = state, let pending = pendingSignup else { return }
        if let at = resendAvailableAt, at > Date() { return }
        codeError = nil
        _ = await requestCode(email: pending.email, password: pending.password)
    }

    /// Abandon a half-finished sign-up and go back to the form.
    ///
    /// The parked request is left on the server to expire on its own. There is no
    /// endpoint to cancel it, and adding one that deletes by address alone would let
    /// anyone wipe a stranger's pending sign-up.
    func useAnotherEmail() {
        pendingSignup = nil
        resendAvailableAt = nil
        codeError = nil
        state = .signedOut
    }

    /// Shared by the first send and every resend.
    ///
    /// Returns whether a code actually went out, so the caller can decide what the
    /// state becomes — the first send moves to the code screen, a resend is already
    /// there and only restarts the countdown.
    private func requestCode(email: String, password: String) async -> Bool {
        struct Body: Encodable {
            let email: String
            let password: String
            let displayName: String?
            let timezone: String
        }
        struct CodeSent: Decodable {
            let expiresIn: Int
            let resendIn: Int
        }
        do {
            let sent: CodeSent = try await APIClient.post(
                config.apiBaseURL.appending(path: "/v1/auth/signup"),
                body: Body(
                    email: email, password: password, displayName: nil,
                    timezone: TimeZone.current.identifier
                )
            )
            resendAvailableAt = Date().addingTimeInterval(TimeInterval(sent.resendIn))
            return true
        } catch let error as MutationError {
            report(error.message)
            return false
        } catch {
            report(Self.readable(error))
            return false
        }
    }

    /// A failure before the code screen is a dead end and belongs on the form; one
    /// raised while the screen is up belongs under the code field.
    private func report(_ message: String) {
        if case .awaitingCode = state {
            codeError = message
        } else {
            state = .failed(message)
        }
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
            try adopt(response.stored(provider: "Email"))
        } catch let error as MutationError {
            state = .failed(error.message)
        } catch {
            state = .failed(Self.readable(error))
        }
    }

    /// Take a freshly issued session: claim any history written before it existed,
    /// store it, and announce it.
    ///
    /// Claiming comes first deliberately. If the store belongs to somebody else, the
    /// session is parked rather than written — otherwise the app would be signed in
    /// as one person while holding another person's hours. Nothing is decided here;
    /// the window asks, and `confirmTransfer()` is the only way through.
    private func adopt(_ session: StoredSession) throws {
        if try repo.ownerToDisplace(signingInAs: session.userID) != nil {
            pendingTransfer = session
            state = .needsTransferConfirmation(email: session.email)
            return
        }
        try repo.claimLocalData(forUserID: session.userID)
        try commit(session)
    }

    /// Take the parked session and move this machine's history onto it.
    ///
    /// The rows are kept, not discarded — the hours were tracked on this machine and
    /// the person switching accounts is usually the same person. They are re-issued
    /// under new identities, which is what stops them being pushed on top of the
    /// previous owner's rows; see `transferLocalData`.
    func confirmTransfer() {
        guard let session = pendingTransfer else { return }
        pendingTransfer = nil
        do {
            try repo.transferLocalData(toUserID: session.userID)
            try commit(session)
        } catch {
            state = .failed(Self.readable(error))
        }
    }

    /// Decline the switch. The session issued for it is dropped unwritten, so the
    /// store still belongs to whoever it belonged to a moment ago.
    func cancelTransfer() {
        pendingTransfer = nil
        state = .signedOut
    }

    /// The account this machine's history currently belongs to, for the question the
    /// window asks. Nil once there is nothing pending.
    var transferWouldDisplace: String? {
        guard let session = pendingTransfer else { return nil }
        return try? repo.ownerToDisplace(signingInAs: session.userID)
    }

    private func commit(_ session: StoredSession) throws {
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

    /// Abandon an in-flight sign-in, from the Settings row's Cancel.
    ///
    /// Cancelling the browser session makes its completion handler fire with
    /// `canceledLogin`, which `signIn()` already treats as signed out — so the state
    /// unwinds through the one path rather than a second one written for this.
    func cancelSignIn() {
        webAuthSession?.cancel()
        webAuthSession = nil
        if case .signingIn = state { state = .signedOut }
    }

    /// The provider behind the current session, for display.
    var currentProvider: String? { session?.provider }

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

    func stored(now: Date = Date(), provider: String = "Google") -> StoredSession {
        StoredSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessExpiresAt: EpochMs(now.timeIntervalSince1970 * 1000) + EpochMs(expiresIn) * 1000,
            userID: user.id,
            email: user.email,
            displayName: user.displayName,
            provider: provider
        )
    }
}
