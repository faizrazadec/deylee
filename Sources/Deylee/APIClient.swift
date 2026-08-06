import DeyleeKit
import Foundation

/// Where this build talks to, and as whom.
///
/// All three values are public by design — a client id and a base URL ship inside
/// every copy of the app — so they live in `Info.plist` rather than in a secret
/// store. Reading them from the bundle rather than hard-coding them is what lets a
/// development build point at localhost without a source change.
struct ClientConfig: Sendable {
    let apiBaseURL: URL
    let googleClientID: String

    /// Google hands a native app back through a URL scheme derived from the client
    /// id with its components reversed. Deriving it rather than configuring it
    /// separately removes a way for the two to disagree.
    var googleCallbackScheme: String {
        "com.googleusercontent.apps." + googleClientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    var googleRedirectURI: String { googleCallbackScheme + ":/oauth2redirect" }

    static func fromBundle(_ bundle: Bundle = .main) -> ClientConfig? {
        guard let base = bundle.object(forInfoDictionaryKey: "DeyleeAPIBaseURL") as? String,
              let url = URL(string: base),
              let clientID = bundle.object(forInfoDictionaryKey: "DeyleeGoogleClientID") as? String,
              !clientID.isEmpty
        else { return nil }
        return ClientConfig(apiBaseURL: url, googleClientID: clientID)
    }
}

/// The HTTP the app speaks to its own API.
///
/// Small on purpose. Everything is one endpoint shape — POST JSON, get JSON back —
/// and the interesting decisions live in the services rather than here.
enum APIClient {
    struct HTTPFailure: Error, CustomStringConvertible {
        let status: Int
        let message: String

        var isUnauthorized: Bool { status == 401 }
        /// The client is ahead of the server: it is talking to a restored backup and
        /// must resync from zero rather than keep asking for rows past a cursor the
        /// server has never issued.
        var needsFullResync: Bool { status == 409 }

        var description: String { "HTTP \(status): \(message)" }
    }

    /// The API returns failures as `{"error":{"message":"…"}}`; surfacing that text
    /// is what lets the UI say why rather than "something went wrong".
    private struct ErrorEnvelope: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }

    static func post<Body: Encodable, Response: Decodable>(
        _ url: URL,
        body: Body,
        bearer: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        // Long enough for a first sync of years of history over a poor connection,
        // short enough that a wedged request does not hold the queue forever.
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPFailure(status: -1, message: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)
                ?? "no detail"
            throw HTTPFailure(status: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
