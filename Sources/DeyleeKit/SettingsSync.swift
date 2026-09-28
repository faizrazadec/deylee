import Foundation

/// Keeps a person's preferences in their account, so a new Mac or a wiped one gets them
/// back. The wire rules are in `docs/SYNC_PROTOCOL.md`, "Settings".
///
/// Local first, like everything else: a change is written to the preferences store and
/// takes effect at once, and this only records that it has not been sent. Offline, a
/// setting still changes; the next sync carries it up.
///
/// Last write wins on the whole set, by the time of the last change on each side. The
/// bookkeeping lives in the same `UserDefaults` as the preferences themselves, so the two
/// can only vanish together: an install that lost its preferences also lost the record
/// of having changed them, and takes the account's set rather than pushing its defaults.
public final class SettingsSyncTracker: @unchecked Sendable {
    /// Where sync stands, as persisted.
    public struct State: Codable, Equatable, Sendable {
        /// The last change to a synced setting here, or the account's time once its set
        /// was taken. `nil` means never changed here, so the account's set wins outright.
        public var updatedAt: EpochMs?
        /// A change the account has not acknowledged yet.
        public var dirty: Bool

        public init(updatedAt: EpochMs?, dirty: Bool) {
            self.updatedAt = updatedAt
            self.dirty = dirty
        }
    }

    /// Stay on this Mac. Screen capture is the recorded person's own switch on the
    /// machine being recorded, so no server row may reach it; launch at login and the
    /// sync switch belong to one machine.
    public static let localOnlyKeys: Set<PreferenceKey> = [
        .screenCaptureEnabled, .screenCaptureIntervalMinutes, .screenCaptureRetentionDays,
        .launchAtLogin, .settingsSyncEnabled,
    ]

    public static let syncedKeys = PreferenceKey.allCases.filter { !localOnlyKeys.contains($0) }

    public static let stateKey = "preferencesSync"

    private let store: PreferencesStore
    private let defaults: UserDefaults
    private let now: @Sendable () -> EpochMs
    private let lock = NSLock()
    private var state: State
    /// The synced part of the store as last seen, so a write to a local-only key, or one
    /// that changes nothing, is not a change to send.
    private var lastPayload: [String: PreferenceValue]
    private var unsubscribe: PreferencesUnsubscribe?

    public init(
        store: PreferencesStore,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> EpochMs = { EpochMs(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
        lastPayload = Self.payload(store.getAll())
        if let data = defaults.data(forKey: Self.stateKey),
           let stored = try? JSONDecoder().decode(State.self, from: data) {
            state = stored
        } else if lastPayload != Self.payload(.defaults) {
            // Chosen before sync existed. Sent as the oldest possible version, so it fills
            // an empty account but loses to any set the account already holds.
            state = State(updatedAt: 0, dirty: true)
        } else {
            state = State(updatedAt: nil, dirty: false)
        }
        unsubscribe = store.onChange { [weak self] next in self?.observe(next) }
    }

    deinit { unsubscribe?() }

    public var current: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// The set to send and its time, or nil when the account already has everything.
    public func pending() -> (settings: [String: PreferenceValue], updatedAt: EpochMs)? {
        lock.lock()
        defer { lock.unlock() }
        guard state.dirty, let updatedAt = state.updatedAt else { return nil }
        return (Self.payload(store.getAll()), updatedAt)
    }

    /// Applies the account's answer: its set when that is newer than the last change
    /// here, and either way clears what the account has now acknowledged.
    public func receive(settings: [String: PreferenceValue]?, updatedAt remote: EpochMs?) {
        lock.lock()
        var adopted: Preferences?
        if let settings, let remote, state.updatedAt.map({ remote > $0 }) ?? true {
            let merged = Self.merging(settings, into: store.getAll())
            adopted = merged
            // Before the write, so the change it announces is not taken for a new one.
            lastPayload = Self.payload(merged)
            state = State(updatedAt: remote, dirty: false)
        } else if let local = state.updatedAt, let remote, remote >= local {
            state.dirty = false
        }
        save()
        lock.unlock()

        if let adopted { store.set(\.self, to: adopted) }
    }

    /// Every synced setting back to its default, here and, on the next sync, in the
    /// account and on every other device. Local-only settings are left alone.
    public func resetToDefaults() {
        let reset = Self.merging(Self.payload(.defaults), into: store.getAll())
        lock.lock()
        lastPayload = Self.payload(reset)
        // Marked even if nothing changed here: the account, or another Mac, may differ.
        state = State(updatedAt: now(), dirty: true)
        save()
        lock.unlock()
        store.set(\.self, to: reset)
    }

    private func observe(_ next: Preferences) {
        let payload = Self.payload(next)
        lock.lock()
        defer { lock.unlock() }
        guard payload != lastPayload else { return }
        lastPayload = payload
        state = State(updatedAt: now(), dirty: true)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    // MARK: Pure rules

    /// The synced keys of a set, in the shape the wire and the store both use.
    public static func payload(_ prefs: Preferences) -> [String: PreferenceValue] {
        let raw = prefs.rawValues
        return Dictionary(uniqueKeysWithValues: syncedKeys.compactMap { key in
            raw[key.rawValue].map { (key.rawValue, $0) }
        })
    }

    /// The account's set laid over this Mac's: synced keys only, each clamped as if read
    /// from the store, and any key missing or malformed keeps this Mac's value.
    public static func merging(
        _ remote: [String: PreferenceValue], into local: Preferences
    ) -> Preferences {
        var raw = local.rawValues
        for key in syncedKeys {
            if let value = remote[key.rawValue] { raw[key.rawValue] = value }
        }
        return Preferences.sanitized(raw: raw, fallback: local)
    }
}
