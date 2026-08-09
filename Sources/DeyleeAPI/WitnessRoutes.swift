import Foundation
import Hummingbird
import Logging
import PostgresNIO

/// The heartbeat: a running timer saying "still here", stamped with the server's
/// clock on arrival.
///
/// This endpoint deliberately learns nothing from the request beyond who sent it
/// and from which device. No timestamp is accepted — the whole point is that a
/// beat can only be recorded in the present, so hours "witnessed" cannot be
/// manufactured after the fact by anything, including a stolen token. The reply
/// says whether a row was written, which the client only uses to avoid logging
/// noise; a beat inside the server's dedup floor is a success, not an error.
struct WitnessController: Sendable {
    let store: Store
    let tokens: TokenService
    let logger: Logger

    struct BeatRequest: Decodable {
        let deviceId: UUID?
    }

    struct BeatResponse: Codable, ResponseEncodable {
        let recorded: Bool
    }

    func addRoutes(to router: Router<DeyleeRequestContext>) {
        router.post("/v1/beat", use: beat)
    }

    @Sendable
    func beat(_ request: Request, context: DeyleeRequestContext) async throws -> BeatResponse {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let payload = try? await tokens.verifyAccessToken(
                  String(header.dropFirst("Bearer ".count))),
              let userID = UUID(uuidString: payload.sub.value)
        else {
            throw HTTPError(.unauthorized, message: "A bearer token is required.")
        }
        let body = try? await request.decode(as: BeatRequest.self, context: context)

        // Through the tenancy-scoped path like every other user write: the
        // SECURITY DEFINER function reads app.user_id itself, so even this route
        // cannot vouch for a different user than the token names.
        let recorded = try await store.withUser(userID) { connection in
            let rows = try await connection.query(
                "SELECT public.record_witness_beat(\(body?.deviceId))",
                logger: logger
            ).collect()
            return (try? rows.first?.decode(Bool.self)) ?? false
        }
        return BeatResponse(recorded: recorded)
    }
}
