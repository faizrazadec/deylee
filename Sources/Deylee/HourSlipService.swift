import DeyleeKit
import Foundation

/// Asks the server to sign an hour slip (SYNC_PROTOCOL.md, *Hour slips*).
///
/// Syncs first. The server signs what it holds, and a correction made on this Mac a
/// minute ago that has not gone up yet would otherwise be missing from a document whose
/// whole value is being right.
@MainActor
final class HourSlipService {
    private let config: ClientConfig
    private let auth: AuthService
    private let sync: SyncService

    init(config: ClientConfig, auth: AuthService, sync: SyncService) {
        self.config = config
        self.auth = auth
        self.sync = sync
    }

    enum Failure: Error, CustomStringConvertible {
        case signedOut
        case refused(String)
        case unreachable

        var description: String {
            switch self {
            case .signedOut: "Your session has expired. Sign in again to create an hour slip."
            case .refused(let why): why
            case .unreachable: "Could not reach Deylee. Check your connection and try again."
            }
        }
    }

    private struct Request: Encodable {
        let from: String
        let to: String
        let timeZone: String
    }

    func create(from: DateKey, to: DateKey, in zone: TimeZone = .current) async throws -> HourSlip {
        await sync.syncNow()
        guard let token = await auth.accessToken() else { throw Failure.signedOut }
        do {
            return try await APIClient.post(
                config.apiBaseURL.appending(path: "/v1/hour-slips"),
                body: Request(from: from.description, to: to.description, timeZone: zone.identifier),
                bearer: token
            )
        } catch let failure as APIClient.HTTPFailure {
            // The server words its refusals for a person — a day not over, too long a
            // range — so its sentence is passed through rather than replaced.
            throw failure.isUnauthorized ? Failure.signedOut : Failure.refused(failure.message)
        } catch {
            throw Failure.unreachable
        }
    }
}
