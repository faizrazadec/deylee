import DeyleeKit
import Foundation

/// Sends what somebody typed in the feedback window to the API.
///
/// Nothing is gathered here. The body is exactly the text in the box, and the two
/// fields beside it are the app version and the OS string — the same two facts the
/// window says out loud before anything is sent. No log, no screenshot, no state
/// from the store: a report the sender cannot read in full would be the thing this
/// product exists not to do.
///
/// Unlike the heartbeat, failure is loud. A beat that does not arrive costs the user
/// nothing they can see, but feedback that silently vanishes costs them the thing
/// they just spent a minute writing.
@MainActor
final class FeedbackService {
    private let config: ClientConfig
    private let auth: AuthService

    init(config: ClientConfig, auth: AuthService) {
        self.config = config
        self.auth = auth
    }

    /// The window enforces this too, so the person sees the limit while they type
    /// rather than after they press send. The server has its own, lower still.
    static let maximumCharacters = 4000

    enum Failure: Error, CustomStringConvertible {
        case signedOut
        case refused(String)
        case unreachable

        var description: String {
            switch self {
            case .signedOut:
                "Your session has expired. Sign in again to send this."
            case .refused(let why):
                why
            case .unreachable:
                "Could not reach Deylee. Check your connection and try again."
            }
        }
    }

    private struct Submission: Encodable {
        let body: String
        let appVersion: String
        let osVersion: String
    }

    private struct Answer: Decodable {
        let accepted: Bool
    }

    func send(_ text: String) async throws {
        // An expired refresh token lands here as nil, which is a real signed-out and
        // worth saying plainly rather than reporting as a network problem.
        guard let token = await auth.accessToken() else { throw Failure.signedOut }

        do {
            let _: Answer = try await APIClient.post(
                config.apiBaseURL.appending(path: "/v1/feedback"),
                body: Submission(
                    body: text,
                    appVersion: DeyleeKit.version,
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString
                ),
                bearer: token
            )
        } catch let failure as APIClient.HTTPFailure {
            // The API says why in words meant for a person — an empty body, an hourly
            // limit — so passing its message through beats inventing a worse one.
            throw failure.isUnauthorized ? Failure.signedOut : Failure.refused(failure.message)
        } catch {
            throw Failure.unreachable
        }
    }
}
