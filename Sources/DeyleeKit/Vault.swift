import Foundation

/// The secrets this machine holds, as one value.
///
/// They used to be two Keychain items — the store key and the session — read
/// separately at launch, which is two authorisation prompts whenever macOS does not
/// recognise the running binary. One item is one prompt. Nothing else about them
/// changes: the same bytes, the same accessibility, the same refusal to sync to
/// iCloud.
///
/// The session is `Data` rather than a decoded session on purpose. DeyleeKit has no
/// business knowing what a session looks like — it is the app's shape, and the core is
/// imported by the server, which must never learn it. This type only has to know that
/// one of the two secrets is optional and the other is not.
public struct VaultContents: Codable, Equatable, Sendable {
    /// Thirty-two bytes. The database is unreadable without exactly these.
    public var storeKey: Data
    /// Absent when nobody is signed in, which is an ordinary state.
    public var session: Data?

    public init(storeKey: Data, session: Data? = nil) {
        self.storeKey = storeKey
        self.session = session
    }

    /// Sign out without disturbing the key.
    ///
    /// The dangerous shape this exists to prevent: two secrets in one item invites
    /// deleting the item to sign out, which would take the encryption key with it and
    /// leave every hour ever tracked unreadable. Signing out clears one field.
    public func withoutSession() -> VaultContents {
        VaultContents(storeKey: storeKey, session: nil)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Nil rather than throwing for anything unreadable, so a caller can fall back to
    /// the legacy items instead of concluding the secrets are gone.
    public static func decoded(_ data: Data) -> VaultContents? {
        guard let value = try? JSONDecoder().decode(VaultContents.self, from: data),
              value.storeKey.count == 32
        else { return nil }
        return value
    }
}
