import DeyleeKit
import Foundation
import Security

/// The key that encrypts the local SQLite store, held in the macOS Keychain.
///
/// Thirty-two random bytes, generated once on first launch and never shown, never
/// written to a file, never shipped in the build. That last point is the whole
/// design: a key baked into the binary comes straight back out with `strings`, so
/// the only key worth having is one the machine generates for itself and keeps where
/// the app's own code can reach it and a SQLite browser cannot.
///
/// The honest limit, stated plainly: the person who owns the Mac and knows their
/// login password can still extract this — `security find-generic-password` will
/// hand it over. Encryption stops the casual edit (open the file, change a row), not
/// its owner. What stops forged *hours* is the server, not this key.
///
/// Recovery is sync. Lose the Keychain item — a new Mac, a wiped login — and the
/// file is unreadable for good; signing in re-pulls the history from the server,
/// which is the backup. So this is deliberately not synced to iCloud: a key that
/// followed the account would defeat the point, and the data already travels by its
/// own protected path.
enum StoreKey {
    private static let service = "me.faizraza.deylee.store" + DataStore.keychainSuffix
    private static let account = "encryption-key"
    private static let byteCount = 32

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case randomness(Int32)
        case malformed

        var description: String {
            switch self {
            case .keychain(let status):
                "The Keychain refused the store key (status \(status))."
            case .randomness(let status):
                "The system could not generate a store key (status \(status))."
            case .malformed:
                "The stored key was the wrong size."
            }
        }
    }

    /// The device's key, generated and saved the first time it is asked for.
    static func loadOrCreate() throws -> [UInt8] {
        // Read once without letting macOS put a dialog up. Nil means either no item at
        // all or an item this build is not on the access list of — and only the second
        // of those is worth a question.
        var found = try? loadWithoutPrompting()
        if found == nil { found = try load() }

        guard let existing = found else {
            let fresh = try generate()
            try save(fresh)
            return fresh
        }
        return existing
    }

    // On rewriting the item to make macOS stop asking, which 0.4.2 tried and 0.4.3
    // removed. The access list has a second entry, ACLAuthorizationChangeACL, whose
    // trusted-application list is empty: no program may rewrite the item without the
    // user typing their Keychain password, ever, including Deylee. So the rewrite
    // could not be done quietly — it replaced one prompt with two, and when it was
    // refused it simply ran again on the next launch.
    //
    // There is no way to fix this from inside the app, because the thing macOS objects
    // to is the app's identity. Ad-hoc signing gives Deylee a designated requirement of
    // `cdhash H"..."` — the hash of that exact binary — so every build really is a
    // different program as far as the Keychain is concerned. A Developer ID replaces
    // that with `identifier "me.faizraza.deylee" and anchor apple generic and
    // certificate leaf[subject.OU] = <team>`, which every future build satisfies, and
    // the question stops being asked. Until then, Always Allow answers it once per
    // update; Allow answers it once per launch.

    /// `load()`, with macOS forbidden from asking the user anything. Returns nil rather
    /// than prompting when this build is a stranger to the item.
    private static func loadWithoutPrompting() throws -> [UInt8]? {
        try load(promptIfNeeded: false)
    }

    private static func generate() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else { throw Failure.randomness(status) }
        return bytes
    }

    private static func load(promptIfNeeded: Bool = true) throws -> [UInt8]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !promptIfNeeded {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = item as? Data, data.count == byteCount else {
            throw Failure.malformed
        }
        return [UInt8](data)
    }

    private static func save(_ key: [UInt8]) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(key)
        // Available after the first unlock, so a login-time relaunch can open the
        // store; not synchronised to iCloud, so the key never leaves this Mac.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
