import DeyleeKit
import Foundation
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
enum TokenStore {
    /// Scoped to the bundle id so a debug build and a release build do not fight
    /// over one item.
    private static let service = "me.faizraza.deylee.session"
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add rather than update: it is one code path instead of two,
        // and the item is small enough that rewriting it costs nothing.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Not synchronised to iCloud, and unavailable until the Mac has been
        // unlocked once — a background sync before first unlock would fail anyway.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func load() throws -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.keychain(status)
        }
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            // A session written by an older build that cannot be read is not an
            // error worth stopping for: signing in again fixes it.
            throw Failure.malformed
        }
        return session
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
