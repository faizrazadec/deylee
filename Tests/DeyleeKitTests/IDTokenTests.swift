import Foundation
import Testing
@testable import DeyleeKit

/// Builds a token shaped like a real one: three dot-separated segments, the middle
/// carrying base64url-encoded JSON with no padding, exactly as Google sends it.
private func makeToken(payload: String) -> String {
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

@Suite("IDToken")
struct IDTokenTests {
    @Test func readsThePictureClaim() {
        let token = makeToken(payload: #"{"sub":"1","email":"a@b.c","picture":"https://lh3.googleusercontent.com/a/x=s96-c"}"#)
        #expect(IDToken.pictureURL(in: token)?.absoluteString
                == "https://lh3.googleusercontent.com/a/x=s96-c")
    }

    /// An account made with an email address has no picture, which is ordinary.
    @Test func noClaimIsNotAnError() {
        #expect(IDToken.pictureURL(in: makeToken(payload: #"{"email":"a@b.c"}"#)) == nil)
    }

    /// The padding is the part most likely to be got wrong, and a payload whose
    /// length lands on each remainder is the only way to know it was not.
    @Test(arguments: [
        #"{"picture":"https://e.com/1"}"#,
        #"{"picture":"https://e.com/12"}"#,
        #"{"picture":"https://e.com/123"}"#,
        #"{"picture":"https://e.com/1234"}"#,
        #"{"picture":"https://e.com/12345"}"#,
        #"{"picture":"https://e.com/123456"}"#,
    ])
    func decodesWhateverLengthTheClaimHappensToBe(payload: String) {
        let expected = String(payload.dropFirst(#"{"picture":""#.count).dropLast(2))
        #expect(IDToken.pictureURL(in: makeToken(payload: payload))?.absoluteString == expected)
    }

    /// Base64url swaps two characters out; a payload containing them decodes to
    /// nothing at all if they are not swapped back.
    @Test func handlesTheUrlSafeAlphabet() {
        // '~' and '?' land on '+' and '/' in standard base64, so this payload only
        // survives the round trip if the substitution is undone.
        let token = makeToken(payload: #"{"n":"~~~???","picture":"https://e.com/a"}"#)
        #expect(IDToken.pictureURL(in: token)?.absoluteString == "https://e.com/a")
    }

    @Test func refusesPlainHttp() {
        #expect(IDToken.pictureURL(in: makeToken(payload: #"{"picture":"http://e.com/a"}"#)) == nil)
    }

    @Test(arguments: ["", "one.two", "a.b.c.d", "header..signature", "not-a-token"])
    func refusesMalformedTokens(token: String) {
        #expect(IDToken.pictureURL(in: token) == nil)
    }

    /// Nothing is verified here, so a token nobody signed still parses. The comment on
    /// IDToken says so; this pins it, because a future reader might "fix" it.
    @Test func doesNotPretendToVerifyAnything() {
        let token = makeToken(payload: #"{"picture":"https://e.com/a","iss":"https://evil.example"}"#)
        #expect(IDToken.pictureURL(in: token) != nil)
    }
}
