import DeyleeKit
import Foundation
import LocalAuthentication
import Security

/// The session, as this device holds it.
///
/// The refresh token is the long-lived half and the one worth stealing: it can be
/// traded for a fresh access token for ninety days. It lives in the Keychain and
/// nowhere else — never in the SQLite store, never in `UserDefaults`, never in a
/// log line.
struct StoredSession: Sendable, Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// When the access token stops being accepted, in epoch milliseconds.
    var accessExpiresAt: EpochMs
    var userID: String
    var email: String
    var displayName: String?
    /// How this session was obtained, for the Settings row: the spec shows
    /// "Synced 2 min ago · Google", and the provider is not derivable afterwards.
    var provider: String = "Google"

    /// Treated as expired a minute early, so a token does not lapse mid-flight and
    /// turn an ordinary sync into a spurious 401.
    func isAccessTokenUsable(at now: EpochMs) -> Bool {
        accessExpiresAt - 60_000 > now
    }
}

/// Keychain-backed storage for the session.
///
/// One item, replaced wholesale. There is no partial state worth keeping: an access
/// token without its refresh token is an hour from useless, and a refresh token
/// without the user id it belongs to cannot be attributed.
@MainActor
enum TokenStore {
    /// Scoped to the bundle id so a debug build and a release build do not fight
    /// over one item.
    private static let service = "me.faizraza.deylee.session" + DataStore.keychainSuffix
    private static let account = "primary"

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case malformed

        var description: String {
            switch self {
            case .keychain(let status):
                "The Keychain refused the operation (status \(status))."
            case .malformed:
                "The stored session could not be read."
            }
        }
    }

    static func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let vault = try SecretVault.load() else {
            // No vault means no store key, and the app cannot have got this far
            // without one — it opens the database before anyone can sign in.
            throw Failure.keychain(errSecItemNotFound)
        }
        try SecretVault.save(VaultContents(storeKey: vault.storeKey, session: data))
    }

    /// The session held on this machine, or nil when nobody is signed in.
    static func load() throws -> StoredSession? {
        guard let data = try SecretVault.load()?.session else { return nil }
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            // Written by an older build in a shape this one cannot read. Not an error
            // worth stopping for: signing in again replaces it.
            throw Failure.malformed
        }
        return session
    }

    /// Sign out, keeping the store key.
    ///
    /// One field, never the whole item. Deleting the vault to sign somebody out would
    /// take the encryption key with it and leave every hour they ever tracked
    /// unreadable — the one mistake that merging the two items makes easy to reach.
    static func clear() {
        guard let vault = try? SecretVault.load() else { return }
        try? SecretVault.save(vault.withoutSession())
    }
}
