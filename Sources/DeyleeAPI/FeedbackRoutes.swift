import Foundation
import Hummingbird
import Logging
import PostgresNIO

/// Feedback the user typed and pressed send on.
///
/// Authenticated, and deliberately so. Anonymous feedback cannot be answered and
/// cannot be rate limited honestly, so an account is the price of the button —
/// the same account the app already requires before a day can be started.
///
/// The route learns nothing the request does not carry: no IP is stored, no
/// header is kept, and the only fields written are the text, the app version and
/// the OS string. The author comes from the token by way of the tenancy-scoped
/// path, never from the body, so a request cannot file feedback as somebody else.
struct FeedbackController: Sendable {
    let store: Store
    let tokens: TokenService
    let logger: Logger

    /// The client's limit is 4000 characters and so is the column's. This one is
    /// the wire's, sized to refuse an obviously absurd body before it reaches the
    /// database rather than after.
    private static let maximumBodyBytes = 8000

    struct SubmitRequest: Decodable {
        let body: String
        let appVersion: String?
        let osVersion: String?
    }

    struct SubmitResponse: Codable, ResponseEncodable {
        let accepted: Bool
    }

    func addRoutes(to router: Router<DeyleeRequestContext>) {
        router.post("/v1/feedback", use: submit)
    }

    @Sendable
    func submit(_ request: Request, context: DeyleeRequestContext) async throws -> SubmitResponse {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let payload = try? await tokens.verifyAccessToken(
                  String(header.dropFirst("Bearer ".count))),
              let userID = UUID(uuidString: payload.sub.value)
        else {
            throw HTTPError(.unauthorized, message: "A bearer token is required.")
        }

        guard let submission = try? await request.decode(as: SubmitRequest.self, context: context)
        else {
            throw HTTPError(.badRequest, message: "A feedback body is required.")
        }

        let text = submission.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw HTTPError(.badRequest, message: "Feedback cannot be empty.")
        }
        guard text.utf8.count <= Self.maximumBodyBytes else {
            throw HTTPError(.contentTooLarge, message: "That feedback is too long to send.")
        }

        // Through the tenancy-scoped path like every other user write: the
        // SECURITY DEFINER function reads app.user_id itself, so this route cannot
        // vouch for a different author than the token names.
        let accepted = try await store.withUser(userID) { connection in
            let rows = try await connection.query(
                """
                SELECT public.submit_feedback(\(text), \(submission.appVersion), \
                \(submission.osVersion))
                """,
                logger: logger
            ).collect()
            return (try? rows.first?.decode(Bool.self)) ?? false
        }

        // False is the hourly limit, not a failure to understand the request, and
        // it is the one refusal worth telling the user about in those words.
        guard accepted else {
            throw HTTPError(.tooManyRequests, message: "That is a lot of feedback in one hour. Try again later.")
        }
        return SubmitResponse(accepted: true)
    }
}
