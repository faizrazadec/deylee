import DeyleeKit
import Foundation
import LocalAuthentication
import Security

/// One Keychain item holding both secrets, read once per launch.
///
/// There were two — `…deylee.store` and `…deylee.session` — read separately at
/// startup. Every read macOS cannot attribute to the running binary costs an
/// authorisation dialog, so two items meant two dialogs on every launch after an
/// update. One item means one.
///
/// It does not mean none. The write that persists a rotated refresh token still costs
/// its own dialog, and cannot be deferred to avoid it: a token used but not written is
/// a token the server has already superseded, so the next launch would present a
/// replayed one and have the whole chain revoked. A dialog is better than a sign-out.
/// Zero dialogs needs a stable code identity — see issue #30.
///
/// Read once and held for the process's life. Nothing here changes underneath us: this
/// app is the only writer, and a second instance sharing the store is not a supported
/// state.
@MainActor
enum SecretVault {
    private static let service = "me.faizraza.deylee.vault" + DataStore.keychainSuffix
    private static let account = "primary"

    /// The items this replaced. Read once during migration, then removed.
    ///
    /// Each carries its own account name, and they differ — the key was filed under
    /// "encryption-key" and the session under "primary". Reading both under one name
    /// finds neither, which for the key means an existing store looks unopenable.
    private static let legacyStore =
        (service: "me.faizraza.deylee.store" + DataStore.keychainSuffix, account: "encryption-key")
    private static let legacySession =
        (service: "me.faizraza.deylee.session" + DataStore.keychainSuffix, account: "primary")

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)

        var description: String {
            switch self {
            case .keychain(let status):
                "The Keychain refused the operation (status \(status))."
            }
        }
    }

    /// Held after the first successful read.
    ///
    /// This is not an optimisation, it is the mechanism: two reads of one item still
    /// cost two dialogs, so the key read at boot and the session read a moment later
    /// have to be the *same* read. `@MainActor` because every caller is already there
    /// — boot, the auth service, the settings model — and a lock would be ceremony
    /// around state only one thread ever touches.
    private static var cached: VaultContents?

    // MARK: Reading

    /// The vault, or nil when this machine has never held one.
    ///
    /// Throws only when the Keychain refused — which the callers must tell apart from
    /// absence, because "no secrets yet" and "not allowed to look" call for opposite
    /// responses.
    static func load() throws -> VaultContents? {
        if let cached { return cached }

        if let data = try read(service: service, account: account),
           let vault = VaultContents.decoded(data) {
            cached = vault
            return vault
        }

        // Nothing under the new service. Either this is a first run, or it is a build
        // that has not migrated yet.
        guard let migrated = try migrateFromLegacyItems() else { return nil }
        cached = migrated
        return migrated
    }

    /// Read once without letting macOS put a dialog up, then again allowing one.
    ///
    /// The silent attempt succeeds whenever the item's access list already names this
    /// build, which is the ordinary case and costs nothing.
    private static func read(service: String, account: String) throws -> Data? {
        if let data = try? read(service: service, account: account, promptIfNeeded: false) {
            return data
        }
        return try read(service: service, account: account, promptIfNeeded: true)
    }

    private static func read(
        service: String, account: String, promptIfNeeded: Bool
    ) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !promptIfNeeded {
            // Verified equivalent to the deprecated kSecUseAuthenticationUIFail on the
            // file-based Keychain these items live in, which is not obvious: LAContext
            // reads as being about Touch ID, and this needs the plain access-list dialog
            // suppressed. Both return errSecInvalidOwnerEdit on an operation the access
            // list refuses, rather than stopping to ask.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.keychain(status)
        }
        return data
    }

    // MARK: Writing

    /// Replace the vault's contents.
    ///
    /// `SecItemUpdate` before `SecItemAdd`, never delete-then-add: replacing an item
    /// rewrites its access list, which nothing may do without the user's Keychain
    /// password, so every save raised a dialog. Writing only the value asks far less.
    static func save(_ vault: VaultContents) throws {
        let data = try vault.encoded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated != errSecSuccess {
            guard updated == errSecItemNotFound else { throw Failure.keychain(updated) }
            var attributes = query
            attributes[kSecValueData as String] = data
            // Unavailable until the Mac has been unlocked once, and never synced to
            // iCloud: the key must not follow the account to another machine.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        }
        cached = vault
    }

    // MARK: Migration

    /// Fold the two old items into one, if they are there.
    ///
    /// Deliberately conservative about the order. The old items are removed only after
    /// the new one has been written *and read back intact* — one of the two secrets is
    /// the only thing that can decrypt this machine's history, and a migration that
    /// deletes before confirming is a migration that can lose it.
    ///
    /// A failure anywhere leaves everything exactly as it was, and the app carries on
    /// against the old items. The cost of retrying next launch is a dialog; the cost of
    /// being clever here is somebody's year of work.
    private static func migrateFromLegacyItems() throws -> VaultContents? {
        guard let keyData = try read(service: legacyStore.service, account: legacyStore.account),
              keyData.count == 32
        else { return nil }
        // Absent is fine and ordinary: a store key with nobody signed in.
        let sessionData = try? read(service: legacySession.service, account: legacySession.account)

        let vault = VaultContents(storeKey: keyData, session: sessionData)
        try save(vault)

        // Read it back through a fresh query rather than trusting the write.
        guard let written = try read(service: service, account: account),
              let confirmed = VaultContents.decoded(written),
              confirmed.storeKey == keyData
        else {
            // The vault is not trustworthy, so the old items stay. `save` cached the
            // value; drop it so the next attempt starts from the Keychain.
            cached = nil
            return nil
        }

        for old in [legacyStore, legacySession] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: old.service,
                kSecAttrAccount as String: old.account,
            ] as CFDictionary)
        }
        return confirmed
    }
}
