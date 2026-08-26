import Foundation

/// Reading claims out of an OpenID Connect ID token.
///
/// Deliberately *unverified*, and that is worth stating rather than leaving to be
/// discovered: nothing here checks a signature, an issuer or an expiry. The server
/// verifies this same token properly before any of it is believed, and nothing this
/// returns is trusted with a decision. It exists so the client can read a claim it
/// was already given, for a picture, without asking anybody for anything.
///
/// Never use this to establish who somebody is.
public enum IDToken {
    /// The `picture` claim, when the token carries one and it is an https URL.
    ///
    /// Returns nil rather than throwing for every kind of malformed input. A missing
    /// or unreadable claim means "no picture", which is an ordinary outcome — an
    /// account signed up by email has no picture at all — and not an error worth
    /// interrupting a successful sign-in for.
    public static func pictureURL(in token: String) -> URL? {
        guard let payload = payload(of: token),
              let claims = try? JSONDecoder().decode(PictureClaim.self, from: payload),
              let picture = claims.picture,
              let url = URL(string: picture),
              // http would hand the address to anybody on the network, and no issuer
              // worth reading returns one.
              url.scheme == "https"
        else { return nil }
        return url
    }

    /// The middle segment, base64url-decoded.
    static func payload(of token: String) -> Data? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url omits the padding Foundation's decoder requires. A remainder of
        // one is not a length base64 can produce, and padding it would decode to
        // something arbitrary rather than nothing.
        switch encoded.count % 4 {
        case 0: break
        case 2: encoded += "=="
        case 3: encoded += "="
        default: return nil
        }
        return Data(base64Encoded: encoded)
    }

    private struct PictureClaim: Decodable {
        let picture: String?
    }
}
