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

    // Why macOS asks, in two halves, because they have different answers.
    //
    // READING is guarded by an access list naming the exact code allowed to do it.
    // Signed ad hoc, that was `cdhash H"..."` — the hash of one binary — so every build
    // was a stranger and every update brought the question back. Signing with a
    // certificate makes it `identifier "me.faizraza.deylee" and certificate root =
    // H"..."`, which every future build satisfies. Answering Always Allow once then
    // holds; Allow answers only that one read and changes nothing.
    //
    // WRITING was self-inflicted and is fixed in `save`. The item's access list also
    // carries ACLAuthorizationChangeACL with an empty trusted list, meaning nothing may
    // rewrite the item without the user's Keychain password. Delete-then-add is exactly
    // that rewrite, so every write raised a dialog; SecItemUpdate touches only the value,
    // which is permitted outright, and asks nothing.
    //
    // 0.4.2 tried to end the reading half by rewriting the item, which needed the writing
    // half it did not have — so it asked twice instead of once and retried every launch.

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
        // Update in place when the item is already there, rather than replacing it.
        //
        // Deleting and re-adding looks equivalent and is not. Replacing an item means
        // writing a new access list, and the access list guarding that says NOBODY may
        // do it without the user's Keychain password — so every write raised a dialog,
        // for ever, no matter how the app was signed. Changing only the value asks
        // nothing, because writing a value is permitted outright.
        //
        // It also closes the window where the key exists nowhere. A crash between the
        // delete and the add would have left the database encrypted with a key no
        // longer on this Mac, which is unrecoverable.
        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: Data(key)] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.keychain(updated) }

        var attributes = query
        attributes[kSecValueData as String] = Data(key)
        // Available after the first unlock, so a login-time relaunch can open the
        // store; not synchronised to iCloud, so the key never leaves this Mac.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
