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
@MainActor
enum StoreKey {
    private static let byteCount = 32

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case randomness(Int32)
        case malformed
        case keyMissingForExistingStore

        var description: String {
            switch self {
            case .keychain(let status):
                "The Keychain refused the store key (status \(status))."
            case .randomness(let status):
                "The system could not generate a store key (status \(status))."
            case .malformed:
                "The stored key was the wrong size."
            case .keyMissingForExistingStore:
                """
                This Mac no longer holds the key that encrypts your Deylee history, so \
                the existing database cannot be opened. Nothing has been changed or \
                deleted. Signing in on a fresh store re-downloads whatever had synced; \
                if you have a backup of the Keychain item, restoring it opens this file \
                as it is.
                """
            }
        }
    }

    /// The device's key, generated and saved the first time it is asked for.
    ///
    /// Lives in the vault now, beside the session, so the launch reads one Keychain
    /// item instead of two. The key itself is unchanged — same bytes, same item
    /// contents after migration — only where it is kept has moved.
    static func loadOrCreate() throws -> [UInt8] {
        if let vault = try SecretVault.load() {
            return [UInt8](vault.storeKey)
        }

        // No vault. On a first run that is ordinary and a fresh key is minted.
        //
        // With a store already on disk it is the opposite of ordinary: that file was
        // encrypted with a key this Mac no longer holds, and a new key cannot open it —
        // it can only overwrite the last thing that ever could. Failing here is what
        // keeps a recoverable situation recoverable.
        if FileManager.default.fileExists(atPath: DataStore.databaseURL.path) {
            throw Failure.keyMissingForExistingStore
        }

        let fresh = try generate()
        try SecretVault.save(VaultContents(storeKey: Data(fresh)))
        return fresh
    }

    /// Thirty-two bytes from the system CSPRNG, never derived and never guessable.
    private static func generate() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else { throw Failure.randomness(status) }
        return bytes
    }
}
