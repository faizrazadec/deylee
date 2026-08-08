import DeyleeKit
import Foundation

/// Tells the server, while a work segment is open, that a live timer exists.
///
/// This is what turns hours from "claimed" into "witnessed": the server stamps
/// each beat with its own clock, so no edit to the local store and no replayed
/// request can manufacture having been seen in the past. The beat carries the
/// device id and nothing else — no app names, no titles, no state beyond the
/// fact of running — which is the entire wire budget the product allows.
///
/// Failure is silence by design. Offline is an ordinary way to work, not an
/// error, and a beat that cannot be delivered simply means those minutes stay
/// claimed rather than witnessed. Nothing here may ever surface a dialog or
/// touch the timer's own path.
@MainActor
final class HeartbeatService {
    private let config: ClientConfig
    private let repo: Repository
    private let auth: AuthService

    init(config: ClientConfig, repo: Repository, auth: AuthService) {
        self.config = config
        self.repo = repo
        self.auth = auth
    }

    private struct Beat: Encodable {
        /// A string, matching how the sync layer stores it — the server parses it
        /// to a uuid, and a malformed one simply lands as a null device.
        let deviceId: String?
    }

    private struct Answer: Decodable {
        let recorded: Bool
    }

    /// One beat, fire-and-forget. The server deduplicates anything faster than
    /// its own floor, so calling this too often is wasteful but never wrong.
    func beat() async {
        guard let token = await auth.accessToken() else { return }
        let device = try? repo.syncState().deviceID
        let _: Answer? = try? await APIClient.post(
            config.apiBaseURL.appending(path: "/v1/beat"),
            body: Beat(deviceId: device),
            bearer: token
        )
    }
}
