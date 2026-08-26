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
        /// In flight, carrying which route it went down. The two wait on entirely
        /// different things — one has handed control to a browser and cannot say how
        /// long that will take, the other is a request this app made and is holding
        /// open — so the screen cannot honestly describe them with one sentence.
        case signingIn(via: Route)
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

    /// How a sign-in was started.
    enum Route: Equatable {
        /// Google, through `ASWebAuthenticationSession`. The flow is in a browser
        /// this app does not control and may sit there for as long as somebody takes
        /// to pick an account.
        case browser
        /// An address and password posted to the API. Bounded by one HTTP request.
        case credentials
    }

    @Published private(set) var state: State = .signedOut

    /// A rejected code, shown under the code field.
    ///
    /// Kept apart from `.failed` on purpose. Moving to `.failed` would take the code
    /// screen off the display and drop the person back at the form, having to start
    /// the whole sign-up again because they mistyped one digit.
    /// The signed-in account's picture, once, if Google supplied one.
    @Published private(set) var avatar: Data?

    @Published private(set) var codeError: String?

    /// When another code may be asked for. The server owns the cooldown; this is only
    /// what the countdown is drawn from.
    @Published private(set) var resendAvailableAt: Date?

    /// How long the code stays good, in seconds, as the server reported it.
    ///
    /// Read from the response rather than written into the screen, because the
    /// lifetime is `SIGNUP_CODE_TTL_SECONDS` and lives on the server. A copy of that
    /// number in the client is a second source of truth that drifts the moment the
    /// deployment is tuned, and the screen would then confidently state the wrong
    /// thing to somebody watching a code stop working early.
    @Published private(set) var codeExpiresIn: Int?

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
        // Cheap and local: the bytes are already in the store, so the row is right on
        // the first frame rather than popping in after a request.
        avatar = (try? repo.appState(Repository.appStateAvatar))
            .flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
    }

    /// Reload a session left by a previous launch.
    ///
    /// "No session" and "the Keychain would not hand it over" are different answers and
    /// this used to give them the same one. A `try?` collapsed both into signed out, so
    /// a person who dismissed the macOS authorisation prompt — which appears whenever
    /// the item's access list does not name the running build, an app update being the
    /// ordinary way that happens — was shown the sign-in screen while their tokens sat
    /// in the Keychain, intact and unread.
    ///
    /// Never a reason to fail to start, either way: the app tracks time without an
    /// account, so the worst case is a sentence on the sign-in screen.
    private func restore() {
        do {
            // Nil is the honest absence: no item, nobody signed in.
            guard let stored = try TokenStore.load() else { return }
            session = stored
            state = .signedIn(email: stored.email, userID: stored.userID)
        } catch TokenStore.Failure.malformed {
            // Written by a build that stored a different shape. The tokens are no use
            // to this one and signing in again replaces them.
            return
        } catch {
            // The item exists and macOS refused to unhand it — denied, cancelled, or
            // asked at a moment when it could not ask. Saying "signed out" would be a
            // guess, and the wrong one: nothing has been signed out of.
            state = .failed(
                "Deylee could not unlock your saved session. Quit and reopen to try "
                    + "again, or sign in to replace it."
            )
        }
    }

    // MARK: - Sign in

    func signIn() async {
        state = .signingIn(via: .browser)
        do {
            let verifier = Self.makeCodeVerifier()
            // Same CSPRNG as the verifier, and three independent values: one proves
            // the exchange, one binds the callback, one binds the token.
            let state = Self.makeCodeVerifier()
            let nonce = Self.makeCodeVerifier()
            let code = try await authorize(
                challenge: Self.challenge(for: verifier), state: state, nonce: nonce
            )
            let idToken = try await exchange(code: code, verifier: verifier)
            let session = try await establishSession(idToken: idToken, nonce: nonce)

            // `adopt` claims history written before anyone signed in — everything
            // local is already dirty, so recording the user carries all of it up on
            // the first sync — and parks the session instead if the store turns out
            // to belong to somebody else.
            try adopt(session)

            // After the session, never before it. This is decoration: a picture that
            // fails to arrive must not turn a successful sign-in into a failed one.
            adoptAvatar(fromIDToken: idToken)
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
        state = .signingIn(via: .credentials)
        codeError = nil

        let outcome = await requestCode(email: email, password: password)
        guard outcome != .failed else { return }

        // Held for a resend, which has to send the same credentials again. Cleared
        // the moment the code is accepted or the screen is abandoned.
        pendingSignup = (email: email, password: password)
        state = .awaitingCode(email: email)

        // Coming back to a sign-up already in flight — the window was closed, or the
        // app restarted, and the code screen went with it. The code that was mailed
        // is still good and verification needs only the address and the digits, so
        // this lands where that code can be typed rather than on a dead end.
        if case .alreadySent(let message) = outcome {
            codeError = message
            // The cooldown is running and this reply does not carry how much is left.
            // Assuming it has expired would light a Resend button the server refuses;
            // the countdown corrects itself the moment a real send answers.
            if resendAvailableAt == nil || resendAvailableAt! < Date() {
                resendAvailableAt = Date().addingTimeInterval(Self.assumedResendCooldown)
            }
        }
    }

    /// Used only when the server has told us a code is already out but not when the
    /// next one may be sent. Deliberately generous: a countdown that finishes early
    /// produces a button that fails, and one that finishes late costs a few seconds.
    private static let assumedResendCooldown: TimeInterval = 60

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
    /// What asking for a code produced.
    enum CodeRequest: Equatable {
        case sent
        /// One was already sent and the cooldown has not run out. Not a failure: the
        /// code is sitting in the person's inbox and is still good.
        case alreadySent(String)
        case failed
    }

    private func requestCode(email: String, password: String) async -> CodeRequest {
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
            codeExpiresIn = sent.expiresIn
            return .sent
        } catch let failure as APIClient.HTTPFailure where failure.status == 429 {
            // The server refused to send a second code so soon. The first one is
            // still valid, so this ends on the code screen rather than the form.
            return .alreadySent(failure.message)
        } catch let error as MutationError {
            report(error.message)
            return .failed
        } catch {
            report(Self.readable(error))
            return .failed
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
        state = .signingIn(via: .credentials)
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

    /// Sign out locally, and tell the server if it can be reached.
    ///
    /// Deliberately does *not* delete the local store. The hours belong to the
    /// person who tracked them, and signing out of a sync service is not a request
    /// to destroy them.
    ///
    /// The local half happens first and unconditionally. Signing out on a train has
    /// to work, so the request is sent detached and its failure is not an error —
    /// the tokens are gone from this device either way. What the server call buys is
    /// the other direction: on a machine somebody else now has, the refresh chain
    /// ends instead of living out its ninety days.
    func signOut() {
        let ending = session
        TokenStore.clear()
        session = nil
        state = .signedOut
        // Goes with the session. A face left behind after signing out is the store
        // still saying who used to own it.
        avatar = nil
        try? repo.setAppState(Repository.appStateAvatar, "")

        // A session whose access token has already expired cannot be presented, and
        // there is nothing to send: the server will refuse it, and the refresh token
        // is discarded here regardless.
        guard let ending, ending.isAccessTokenUsable(at: EpochMs(Date().timeIntervalSince1970 * 1000))
        else { return }
        let url = config.apiBaseURL.appending(path: "/v1/auth/signout")
        let bearer = ending.accessToken
        Task.detached {
            struct Empty: Encodable {}
            struct OK: Decodable { let ok: Bool }
            _ = try? await APIClient.post(url, body: Empty(), bearer: bearer) as OK
        }
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
        } catch let failure as APIClient.HTTPFailure where failure.isUnauthorized {
            // A 401 from the refresh route is the only answer that means the chain is
            // actually dead — expired, revoked, or replayed and revoked with it.
            // Signing out is the honest outcome; leaving a session that cannot renew
            // produces a 401 on every sync forever.
            signOut()
            return nil
        } catch {
            // Everything else says this attempt failed, not that the session ended.
            //
            // This used to sign out on any error at all, and the reliable way to hit it
            // was to restart the Mac: the app syncs the instant it launches, the access
            // token is always stale by then, and the network is usually not up yet. The
            // refresh threw, the tokens were deleted, and the network arrived a few
            // seconds later to find them gone — a sign-in demanded after every reboot,
            // and after every lid opened somewhere with no signal.
            //
            // Keeping them costs nothing: `pendingPush` still holds the work, and the
            // next cycle retries on the backoff. Destroying them costs a sign-in.
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
    ///
    /// `state` and `nonce` are separate protections and PKCE replaces neither.
    ///
    /// PKCE makes an intercepted code useless without the verifier. `state` answers a
    /// different question — whether this callback belongs to the request that started
    /// it. A custom-scheme redirect on macOS is claimable by any app registering the
    /// same scheme, and without `state` an attacker-supplied code arriving here is
    /// exchanged as if it were the user's.
    ///
    /// `nonce` binds the ID token to this authorization request, so a token minted
    /// elsewhere for the same `aud` cannot be replayed into a sign-in here. The server
    /// checks it alongside `iss`, `aud` and `email_verified`.
    private func authorize(challenge: String, state: String, nonce: String) async throws -> String {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: config.googleClientID),
            .init(name: "redirect_uri", value: config.googleRedirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
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

        let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems

        // Before the code is so much as read. A callback that cannot prove it belongs
        // to this request is not one to act on, whatever else it carries.
        guard let echoed = returned?.first(where: { $0.name == "state" })?.value,
              Self.constantTimeEquals(echoed, state)
        else {
            throw AuthError.stateMismatch
        }

        guard let code = returned?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.noAuthorizationCode
        }
        return code
    }

    /// Compared without an early exit. `state` is a secret this process chose and the
    /// callback is attacker-influenced; there is no reason to leak its prefix through
    /// how long the comparison takes.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
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
    private func establishSession(idToken: String, nonce: String) async throws -> StoredSession {
        struct Body: Encodable {
            let idToken: String
            let deviceId: String?
            let timezone: String
            /// Sent so the server can check the token was minted for *this* request.
            /// The client could compare it itself, but the client is the party being
            /// impersonated — the check belongs where the token is trusted.
            let nonce: String
        }
        let deviceID = try? repo.syncState().deviceID
        let response: SessionResponseDTO = try await APIClient.post(
            config.apiBaseURL.appending(path: "/v1/auth/google"),
            body: Body(
                idToken: idToken,
                deviceId: deviceID,
                // The server needs this to attribute a day correctly for anyone
                // whose day does not start when the server's does.
                timezone: TimeZone.current.identifier,
                nonce: nonce
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
    case stateMismatch
    case googleRejectedTheExchange(String)

    var description: String {
        switch self {
        case .noAuthorizationCode:
            "Google did not return an authorization code."
        case .stateMismatch:
            "That sign-in did not come back from the request that started it."
        case .googleRejectedTheExchange(let detail):
            "Google refused the token exchange: \(detail)"
        }
    }
}

extension AuthService {
    // MARK: - Account picture

    /// The `picture` claim, fetched once and kept on this Mac.
    ///
    /// Google already sends this — the app asks for the `profile` scope, which is what
    /// puts `name` and `picture` in the token — so nothing new is requested of anybody.
    ///
    /// Fetched once, at sign-in, and stored. The obvious alternative is to hand the URL
    /// to `AsyncImage` and let it load whenever the row draws, and that would put a
    /// request to googleusercontent.com in the render path: an avatar that breaks with
    /// no network, in an app whose whole claim is that it needs none, and a timestamped
    /// signal to Google every time somebody opens Settings. Hours are not the only thing
    /// that should not leave without being chosen.
    private func adoptAvatar(fromIDToken token: String) {
        guard let url = IDToken.pictureURL(in: token) else { return }
        Task { [weak self] in
            guard let bytes = await Self.fetchAvatar(from: url) else { return }
            guard let self else { return }
            self.avatar = bytes
            try? self.repo.setAppState(
                Repository.appStateAvatar, bytes.base64EncodedString()
            )
        }
    }


    /// A cap, because this writes into the store and the URL is somebody else's to
    /// change. Google's default is a 96px square well under a hundred kilobytes.
    private static let avatarByteLimit = 512 * 1024

    private static func fetchAvatar(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= avatarByteLimit,
              NSImage(data: data) != nil
        else { return nil }
        return data
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
