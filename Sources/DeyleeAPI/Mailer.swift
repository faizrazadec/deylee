import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Outbound mail, through Resend.
///
/// `URLSession` rather than a dedicated HTTP client, matching the JWKS fetch in
/// `Tokens.swift`. The API sends two kinds of request in its whole life — a key set
/// it reads and a code it posts — which does not justify another dependency, and
/// `FoundationNetworking` covers the Linux container the same way.
///
/// The body of the mail is not here. It lives in a Resend template, addressed by id,
/// with the code passed as the `otp` variable; copy changes are then a dashboard
/// edit rather than a deploy. The cost is that the template is state outside this
/// repository — if the variable is ever renamed there, mail keeps sending with an
/// empty code and nothing here fails.
struct Mailer: Sendable {
    let apiKey: String
    let from: String
    let templateID: String
    let logger: Logger

    private static let endpoint = URL(string: "https://api.resend.com/emails")!

    enum MailError: Error, CustomStringConvertible {
        case rejected(status: Int, detail: String)
        case unreachable(String)

        var description: String {
            switch self {
            case .rejected(let status, let detail):
                "Resend refused the message (\(status)): \(detail)"
            case .unreachable(let reason):
                "Could not reach Resend: \(reason)"
            }
        }
    }

    /// Send a sign-up code.
    ///
    /// Throws on anything other than a 2xx. The caller must treat that as a failed
    /// request rather than swallowing it: a person staring at a code entry screen
    /// with no mail coming is worse than being told the send failed.
    func sendSignupCode(_ code: String, to recipient: String) async throws {
        // `subject` is required even when a template supplies the body, and
        // html/text/react may not be combined with a template — Resend rejects that
        // pairing outright.
        let body: [String: Any] = [
            "from": from,
            "to": [recipient],
            "subject": "Your Deylee code",
            "template": [
                "id": templateID,
                "variables": ["otp": code],
            ],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MailError.unreachable(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Resend's error body names the offending field, which is most of the
            // value when a template id or a sending domain is wrong.
            let detail = String(data: data, encoding: .utf8) ?? "no detail"
            throw MailError.rejected(status: status, detail: detail)
        }
    }
}

/// A six-digit code, uniformly distributed.
///
/// `SystemRandomNumberGenerator` is seeded by the OS CSPRNG, so this is not the
/// `arc4random_uniform`-modulo-bias trap: `random(in:)` rejects and redraws rather
/// than folding the range. Leading zeros are kept — the code is text, never a
/// number, and "042931" must not become "42931" anywhere between here and the
/// person typing it back.
enum SignupCode {
    static func generate() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
