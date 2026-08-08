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
        /// A code that will not survive the trip through the template's numeric
        /// `otp`. Unreachable while `SignupCode` is the only thing making codes,
        /// and an error rather than a force-unwrap because the alternative is this
        /// type trusting a promise made in another one.
        case malformedCode(String)

        var description: String {
            switch self {
            case .rejected(let status, let detail):
                "Resend refused the message (\(status)): \(detail)"
            case .unreachable(let reason):
                "Could not reach Resend: \(reason)"
            case .malformedCode(let code):
                "Code \(code) is not a whole number and cannot be templated"
            }
        }
    }

    /// Send a sign-up code.
    ///
    /// Throws on anything other than a 2xx. The caller must treat that as a failed
    /// request rather than swallowing it: a person staring at a code entry screen
    /// with no mail coming is worse than being told the send failed.
    func sendSignupCode(_ code: String, to recipient: String) async throws {
        // The template declares `otp` as a number and refuses a string outright, so
        // the code goes over the wire as an integer. That is lossless only because
        // `SignupCode` never draws a leading zero — this line is why that rule
        // exists, and changing either one without the other mails the wrong digits.
        guard let otp = Int(code), String(otp) == code else {
            throw MailError.malformedCode(code)
        }

        // `subject` is required even when a template supplies the body, and
        // html/text/react may not be combined with a template — Resend rejects that
        // pairing outright.
        let body: [String: Any] = [
            "from": from,
            "to": [recipient],
            "subject": "Your Deylee code",
            "template": [
                "id": templateID,
                "variables": ["otp": otp],
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

/// A six-digit code, uniformly distributed, never starting with a zero.
///
/// `SystemRandomNumberGenerator` is seeded by the OS CSPRNG, so this is not the
/// `arc4random_uniform`-modulo-bias trap: `random(in:)` rejects and redraws rather
/// than folding the range.
///
/// The range starts at 100000 because the Resend template types `otp` as a number,
/// and a number cannot carry a leading zero: "042931" would arrive as "42931" and be
/// rejected by the server that made it, for one code in ten. Excluding those codes
/// outright is the honest fix — padding a number back to six digits in the template
/// would put the invariant somewhere this repository cannot test.
///
/// The cost is 900,000 codes rather than 1,000,000. Against a ten-minute expiry and a
/// capped attempt count that is not a meaningful difference; a guesser is stopped by
/// the cap long before the size of the space matters.
enum SignupCode {
    static func generate() -> String {
        String(Int.random(in: 100_000...999_999))
    }
}
