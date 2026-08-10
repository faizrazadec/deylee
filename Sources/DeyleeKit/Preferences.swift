import Foundation

/// User preferences, ported from `src/main/store/preferences.ts`.
///
/// The backing store is user-editable and also survives app downgrades, so nothing read
/// back from it can be trusted: every value is validated and clamped on the way in *and*
/// on the way out. A key whose stored value is missing or the wrong shape falls back to
/// its default individually, so one bad field never costs the user the rest of their
/// settings.
///
/// Two Electron keys are deliberately **not** ported:
///
/// - `miniWindowPositions` — Electron stored top-left window origins keyed by
///   `display.id`. The native mini window remembers its place through AppKit
///   (`CGDirectDisplayID`, bottom-left origins), so the stored coordinates do not
///   transfer and this module ignores the key on read rather than importing garbage.
/// - `trayFallbackNoticeShown` — Linux-only bookkeeping for the "no tray available"
///   notice. macOS always has a status item, so there is nothing to remember.
///
/// Both are preserved-as-ignored: reading a `preferences.json` that contains them yields
/// a complete, valid set of the keys that do apply.

// MARK: - Preference values

/// App-wide appearance. `system` follows the OS setting.
public enum Theme: String, Sendable, Codable, CaseIterable {
    case system
    case light
    case dark
}

// MARK: - Preferences

/// The complete, always-in-range preference set.
///
/// Every instance handed out by a ``PreferencesStore`` has been through
/// ``Preferences/sanitized(fallback:)``, so callers may use the values directly: an `Int`
/// here is already inside its range and a `Double` here is already finite.
public struct Preferences: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var showMiniWindow: Bool

    public var idleDetectionEnabled: Bool
    /// Minutes of system idle before prompting. 1–240.
    public var idleThresholdMinutes: Int

    public var autoPauseOnSleep: Bool
    public var autoPauseOnLock: Bool

    /// Fractional hours (7.5 is meaningful), 0–24.
    public var dailyTargetHours: Double

    public var reminderEnabled: Bool
    /// 0–23, local.
    public var reminderHour: Int
    /// 0–59, local.
    public var reminderMinute: Int

    public var theme: Theme
    public var weekStartsOn: WeekStart

    /// The one and only thing Deylee sends over the network: a poll of the GitHub
    /// Releases feed. No account, no telemetry, no payload — just a version comparison.
    /// Turning this off makes the app completely offline again.
    public var updateCheckEnabled: Bool

    /// Whether Deylee captures the screen while a work timer runs.
    ///
    /// **False on every install, and only the person recorded may change it.** There is
    /// no admin switch, no policy flag and no server-side enable, and adding one is the
    /// refusal in `PRODUCT.md` §6 rather than a feature to weigh — the whole difference
    /// between this and the trackers people resent is who holds this boolean.
    ///
    /// Off also means *nothing runs*: no capture timer is armed and macOS is never asked
    /// for screen-recording permission, so a user who leaves it alone is not prompted.
    public var screenCaptureEnabled: Bool

    /// Minutes between captures while the timer runs.
    public var screenCaptureIntervalMinutes: Int

    /// How many days of captures to keep before they are swept.
    ///
    /// By age rather than by size: "the last fortnight" is something a person can hold
    /// in their head, where a byte budget means the oldest image disappears at a moment
    /// decided by their screen resolution.
    public var screenCaptureRetentionDays: Int

    public init(
        launchAtLogin: Bool,
        showMiniWindow: Bool,
        idleDetectionEnabled: Bool,
        idleThresholdMinutes: Int,
        autoPauseOnSleep: Bool,
        autoPauseOnLock: Bool,
        dailyTargetHours: Double,
        reminderEnabled: Bool,
        reminderHour: Int,
        reminderMinute: Int,
        theme: Theme,
        weekStartsOn: WeekStart,
        updateCheckEnabled: Bool,
        screenCaptureEnabled: Bool = false,
        screenCaptureIntervalMinutes: Int = 10,
        screenCaptureRetentionDays: Int = 90
    ) {
        self.launchAtLogin = launchAtLogin
        self.showMiniWindow = showMiniWindow
        self.idleDetectionEnabled = idleDetectionEnabled
        self.idleThresholdMinutes = idleThresholdMinutes
        self.autoPauseOnSleep = autoPauseOnSleep
        self.autoPauseOnLock = autoPauseOnLock
        self.dailyTargetHours = dailyTargetHours
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.theme = theme
        self.weekStartsOn = weekStartsOn
        self.updateCheckEnabled = updateCheckEnabled
        self.screenCaptureEnabled = screenCaptureEnabled
        self.screenCaptureIntervalMinutes = screenCaptureIntervalMinutes
        self.screenCaptureRetentionDays = screenCaptureRetentionDays
    }

    /// The compiled-in macOS defaults.
    ///
    /// `showMiniWindow` is off: the mini window is opt-in on a platform that already has
    /// the status item on screen at all times. `autoPauseOnLock` is off because a screen
    /// lock during a call or a screensaver is not a break. `updateCheckEnabled` is on
    /// because a tracker nobody can patch is a worse trade than one poll of a public
    /// feed — it is a single preference away from a completely offline app, and nothing
    /// is ever downloaded without the user asking for it.
    public static let defaults = Preferences(
        launchAtLogin: false,
        showMiniWindow: false,
        idleDetectionEnabled: true,
        idleThresholdMinutes: 10,
        autoPauseOnSleep: true,
        autoPauseOnLock: false,
        dailyTargetHours: 8,
        reminderEnabled: false,
        reminderHour: 17,
        reminderMinute: 30,
        theme: .system,
        weekStartsOn: .monday,
        updateCheckEnabled: true,
        // Spelled out rather than left to the parameter default. This is the value the
        // product promise rests on, and it should be visible in the list of defaults
        // somebody reads to check.
        screenCaptureEnabled: false,
        screenCaptureIntervalMinutes: 10,
        screenCaptureRetentionDays: 90
    )

    /// Daily target in whole minutes, the form the `days.target_minutes` column stores.
    /// Always `round(hours × 60)`, and always rounded at the last moment: the hours are
    /// the stored truth, the minutes are a projection of it.
    public var targetMinutes: Int {
        // Re-clamped rather than trusted: a `Preferences` built by hand can hold a value
        // the store would never have returned, and this feeds a NOT NULL column.
        let hours = PreferenceCoercion.numberInRange(
            .number(dailyTargetHours),
            min: PreferenceLimits.dailyTargetMinHours,
            max: PreferenceLimits.dailyTargetMaxHours,
            fallback: Preferences.defaults.dailyTargetHours
        )
        return Int(preferencesJSRound(hours * 60))
    }
}

// MARK: - Ranges

public enum PreferenceLimits {
    public static let idleThresholdMinMinutes = 1
    public static let idleThresholdMaxMinutes = 240
    public static let dailyTargetMaxHours: Double = 24
    public static let dailyTargetMinHours: Double = 0
    public static let reminderHourRange = 0...23

    /// Minutes between captures. The floor is a minute because anything faster is a
    /// screen recorder wearing a timer's clothes, and this product does not ship one.
    public static let screenCaptureIntervalRange = 1...60
    /// Days of captures kept. Capped at a quarter so "keep everything for ever" is not
    /// reachable by dragging a slider — long retention is a decision, not a default that
    /// drifts.
    public static let screenCaptureRetentionRange = 1...90
    public static let reminderMinuteRange = 0...59
}

// MARK: - Untrusted values

/// A single value as it comes out of an untrusted store — `preferences.json`, or a
/// `UserDefaults` blob a previous version wrote.
///
/// This is the Swift stand-in for TypeScript's `unknown`: it can hold every JSON scalar
/// a preference is allowed to be, and collapses everything else into ``other`` so a
/// nested object, an array or `null` is simply "not a usable value here".
public enum PreferenceValue: Equatable, Sendable, Codable {
    case bool(Bool)
    case number(Double)
    case string(String)
    /// `null`, an array, an object — anything no preference is. Always takes the
    /// fallback.
    case other

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .other
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .other: try container.encodeNil()
        }
    }
}

// MARK: - Keys

/// Every preference the macOS app knows about, under the key name the Electron build
/// used, so an imported `preferences.json` lines up field for field.
public enum PreferenceKey: String, Sendable, CaseIterable {
    case launchAtLogin
    case showMiniWindow
    case idleDetectionEnabled
    case idleThresholdMinutes
    case autoPauseOnSleep
    case autoPauseOnLock
    case dailyTargetHours
    case reminderEnabled
    case reminderHour
    case reminderMinute
    case theme
    case weekStartsOn
    case updateCheckEnabled
    case screenCaptureEnabled
    case screenCaptureIntervalMinutes
    case screenCaptureRetentionDays

    /// Keys the Electron file may contain that this platform has no use for. They are
    /// skipped on read and never written; see the file header for why.
    public static let ignoredElectronKeys: Set<String> = [
        "miniWindowPositions",
        "trayFallbackNoticeShown",
    ]
}

/// Why a write was refused. Nothing was stored, and the caller's own value is the only
/// thing lost — the stored preferences are untouched.
public enum PreferenceWriteError: Error, Equatable, Sendable {
    /// A key that is not a preference at all. Writes are reachable from the UI layer, so
    /// an unknown key is rejected rather than stored: nothing may grow the preference
    /// set with arbitrary content.
    case unknownKey(String)
    /// A known key handed a value of the wrong shape.
    case wrongType(PreferenceKey)

    /// The message the UI shows. A preference write is the only operation in the app
    /// allowed to fail loudly, because every value it could silently fall back to is one
    /// the UI would report as saved.
    public var message: String {
        switch self {
        case .unknownKey(let key):
            return "Could not save \"\(key)\": unknown preference, or wrong type."
        case .wrongType(let key):
            return "Could not save \"\(key.rawValue)\": unknown preference, or wrong type."
        }
    }
}

// MARK: - Coercion

/// Rounds half towards positive infinity the way JavaScript's `Math.round` does, so a
/// ported clamp lands on the same integer the Electron build stored.
/// `Double.rounded()` rounds -2.5 to -3; `Math.round(-2.5)` is -2.
///
/// Comparing the fraction against 0.5 rather than computing `floor(value + 0.5)`: the
/// addition is itself rounded, so `0.49999999999999994 + 0.5` is exactly `1.0` and the
/// shorter form would round the largest double below a half *up*, where JavaScript
/// rounds it down.
fileprivate func preferencesJSRound(_ value: Double) -> Double {
    let floor = value.rounded(.down)
    return value - floor >= 0.5 ? floor + 1 : floor
}

/// The pure value rules, lifted out of the store so every clamp is testable without a
/// backing store in sight.
public enum PreferenceCoercion {
    /// Strictly boolean. A `1` or a `"true"` is not a boolean and takes the fallback.
    public static func bool(_ value: PreferenceValue?, fallback: Bool) -> Bool {
        if case .bool(let value) = value { return value }
        return fallback
    }

    /// Clamps into `[min, max]`. A non-number, `NaN` or an infinity takes the fallback.
    public static func numberInRange(
        _ value: PreferenceValue?, min minimum: Double, max maximum: Double, fallback: Double
    ) -> Double {
        guard case .number(let number) = value, number.isFinite else { return fallback }
        // `+ 0` normalises -0.0 to 0.0, which is what `Math.max(0, -0)` yields; without
        // it a stored `-0` would round-trip back out as `-0` where Electron wrote `0`.
        return Swift.min(maximum, Swift.max(minimum, number)) + 0
    }

    /// As ``numberInRange(_:min:max:fallback:)``, rounded first — the clamp is applied to
    /// the rounded value, so a 240.4 threshold is 240 rather than being rounded up out of
    /// range and then pulled back.
    public static func integerInRange(
        _ value: PreferenceValue?, min minimum: Int, max maximum: Int, fallback: Int
    ) -> Int {
        guard case .number(let number) = value, number.isFinite else { return fallback }
        let rounded = preferencesJSRound(number)
        // Clamped as a Double before narrowing: a value beyond Int's range would trap on
        // conversion, and the file is allowed to contain 1e300.
        let clamped = Swift.min(Double(maximum), Swift.max(Double(minimum), rounded))
        return Int(clamped)
    }

    /// Enum membership. Any other string, or a non-string, takes the fallback.
    public static func theme(_ value: PreferenceValue?, fallback: Theme) -> Theme {
        guard case .string(let raw) = value, let theme = Theme(rawValue: raw) else {
            return fallback
        }
        return theme
    }

    /// There are only two weeks in the world, so a stored number is bent to fit rather
    /// than rejected: anything that rounds to 1 or more is Monday, anything else Sunday.
    /// A non-number still takes the fallback.
    public static func weekStart(_ value: PreferenceValue?, fallback: WeekStart) -> WeekStart {
        guard case .number(let number) = value, number.isFinite else { return fallback }
        return preferencesJSRound(number) >= 1 ? .monday : .sunday
    }
}

// MARK: - Sanitising

extension Preferences {
    /// Builds a complete, in-range `Preferences` from anything at all. Each key that is
    /// missing or malformed takes its value from `fallback`, independently of the rest.
    public static func sanitized(
        raw: [String: PreferenceValue], fallback: Preferences = .defaults
    ) -> Preferences {
        let d = fallback
        return Preferences(
            launchAtLogin: PreferenceCoercion.bool(raw["launchAtLogin"], fallback: d.launchAtLogin),
            showMiniWindow: PreferenceCoercion.bool(raw["showMiniWindow"], fallback: d.showMiniWindow),
            idleDetectionEnabled: PreferenceCoercion.bool(
                raw["idleDetectionEnabled"], fallback: d.idleDetectionEnabled),
            idleThresholdMinutes: PreferenceCoercion.integerInRange(
                raw["idleThresholdMinutes"],
                min: PreferenceLimits.idleThresholdMinMinutes,
                max: PreferenceLimits.idleThresholdMaxMinutes,
                fallback: d.idleThresholdMinutes
            ),
            autoPauseOnSleep: PreferenceCoercion.bool(
                raw["autoPauseOnSleep"], fallback: d.autoPauseOnSleep),
            autoPauseOnLock: PreferenceCoercion.bool(
                raw["autoPauseOnLock"], fallback: d.autoPauseOnLock),
            // Fractional targets are meaningful (7.5 h), so this one is not rounded.
            dailyTargetHours: PreferenceCoercion.numberInRange(
                raw["dailyTargetHours"],
                min: PreferenceLimits.dailyTargetMinHours,
                max: PreferenceLimits.dailyTargetMaxHours,
                fallback: d.dailyTargetHours
            ),
            reminderEnabled: PreferenceCoercion.bool(
                raw["reminderEnabled"], fallback: d.reminderEnabled),
            reminderHour: PreferenceCoercion.integerInRange(
                raw["reminderHour"],
                min: PreferenceLimits.reminderHourRange.lowerBound,
                max: PreferenceLimits.reminderHourRange.upperBound,
                fallback: d.reminderHour
            ),
            reminderMinute: PreferenceCoercion.integerInRange(
                raw["reminderMinute"],
                min: PreferenceLimits.reminderMinuteRange.lowerBound,
                max: PreferenceLimits.reminderMinuteRange.upperBound,
                fallback: d.reminderMinute
            ),
            theme: PreferenceCoercion.theme(raw["theme"], fallback: d.theme),
            weekStartsOn: PreferenceCoercion.weekStart(raw["weekStartsOn"], fallback: d.weekStartsOn),
            updateCheckEnabled: PreferenceCoercion.bool(
                raw["updateCheckEnabled"], fallback: d.updateCheckEnabled)
        )
    }

    /// The set as untrusted values again, ready to be written out or re-sanitised.
    public var rawValues: [String: PreferenceValue] {
        [
            "launchAtLogin": .bool(launchAtLogin),
            "showMiniWindow": .bool(showMiniWindow),
            "idleDetectionEnabled": .bool(idleDetectionEnabled),
            "idleThresholdMinutes": .number(Double(idleThresholdMinutes)),
            "autoPauseOnSleep": .bool(autoPauseOnSleep),
            "autoPauseOnLock": .bool(autoPauseOnLock),
            "dailyTargetHours": .number(dailyTargetHours),
            "reminderEnabled": .bool(reminderEnabled),
            "reminderHour": .number(Double(reminderHour)),
            "reminderMinute": .number(Double(reminderMinute)),
            "theme": .string(theme.rawValue),
            "weekStartsOn": .number(Double(weekStartsOn.rawValue)),
            "updateCheckEnabled": .bool(updateCheckEnabled),
            "screenCaptureEnabled": .bool(screenCaptureEnabled),
            "screenCaptureIntervalMinutes": .number(Double(screenCaptureIntervalMinutes)),
            "screenCaptureRetentionDays": .number(Double(screenCaptureRetentionDays)),
        ]
    }

    /// Re-runs the same rules over an already-typed draft, so a value that arrived
    /// through the typed API is clamped exactly as one read off disk would be. Swift's
    /// types rule out most of what the file can contain; a non-finite
    /// `dailyTargetHours` is the one hole left, and it takes `fallback`.
    public func sanitized(fallback: Preferences = .defaults) -> Preferences {
        Preferences.sanitized(raw: rawValues, fallback: fallback)
    }

    /// Decodes the Electron `preferences.json` shape — a flat object under the same key
    /// names — for the importer.
    ///
    /// Per-key salvage still applies: a file where only `theme` is nonsense yields every
    /// other setting the user chose. A file that is not JSON at all, or is not a JSON
    /// object, has nothing per-key to salvage and yields `fallback` whole.
    public static func fromElectronJSON(
        _ data: Data, fallback: Preferences = .defaults
    ) -> Preferences {
        guard let raw = try? JSONDecoder().decode([String: PreferenceValue].self, from: data) else {
            return fallback
        }
        return sanitized(raw: raw, fallback: fallback)
    }

    /// The same set encoded in the Electron `preferences.json` shape. The keys this
    /// platform ignores are not written back, so an export never invents Linux state.
    public func electronJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(rawValues)
    }
}

// MARK: - Typed writes

extension Preferences {
    /// Applies one untrusted value to a draft, rejecting a key that is not a preference
    /// and a value of the wrong shape.
    ///
    /// This mirrors the IPC layer's narrowing, which is deliberately stricter than the
    /// store's own clamping: a write is a thing the user just did, so a value that makes
    /// no sense is refused and reported instead of being bent into range. `weekStartsOn`
    /// is the clearest case — a stored 7 reads back as Monday, but *writing* 7 fails.
    /// Ranges are still clamped afterwards, because a 900-minute idle threshold is a
    /// slider at its limit, not a mistake.
    public mutating func apply(
        _ key: PreferenceKey, _ value: PreferenceValue
    ) throws(PreferenceWriteError) {
        switch key {
        case .launchAtLogin:
            launchAtLogin = try Preferences.requireBool(value, key)
        case .showMiniWindow:
            showMiniWindow = try Preferences.requireBool(value, key)
        case .idleDetectionEnabled:
            idleDetectionEnabled = try Preferences.requireBool(value, key)
        case .autoPauseOnSleep:
            autoPauseOnSleep = try Preferences.requireBool(value, key)
        case .autoPauseOnLock:
            autoPauseOnLock = try Preferences.requireBool(value, key)
        case .reminderEnabled:
            reminderEnabled = try Preferences.requireBool(value, key)
        case .updateCheckEnabled:
            updateCheckEnabled = try Preferences.requireBool(value, key)
        case .screenCaptureEnabled:
            screenCaptureEnabled = try Preferences.requireBool(value, key)

        case .screenCaptureIntervalMinutes:
            screenCaptureIntervalMinutes = PreferenceCoercion.integerInRange(
                .number(try Preferences.requireFinite(value, key)),
                min: PreferenceLimits.screenCaptureIntervalRange.lowerBound,
                max: PreferenceLimits.screenCaptureIntervalRange.upperBound,
                fallback: screenCaptureIntervalMinutes
            )
        case .screenCaptureRetentionDays:
            screenCaptureRetentionDays = PreferenceCoercion.integerInRange(
                .number(try Preferences.requireFinite(value, key)),
                min: PreferenceLimits.screenCaptureRetentionRange.lowerBound,
                max: PreferenceLimits.screenCaptureRetentionRange.upperBound,
                fallback: screenCaptureRetentionDays
            )

        case .idleThresholdMinutes:
            idleThresholdMinutes = PreferenceCoercion.integerInRange(
                .number(try Preferences.requireFinite(value, key)),
                min: PreferenceLimits.idleThresholdMinMinutes,
                max: PreferenceLimits.idleThresholdMaxMinutes,
                fallback: idleThresholdMinutes
            )
        case .reminderHour:
            reminderHour = PreferenceCoercion.integerInRange(
                .number(try Preferences.requireFinite(value, key)),
                min: PreferenceLimits.reminderHourRange.lowerBound,
                max: PreferenceLimits.reminderHourRange.upperBound,
                fallback: reminderHour
            )
        case .reminderMinute:
            reminderMinute = PreferenceCoercion.integerInRange(
                .number(try Preferences.requireFinite(value, key)),
                min: PreferenceLimits.reminderMinuteRange.lowerBound,
                max: PreferenceLimits.reminderMinuteRange.upperBound,
                fallback: reminderMinute
            )
        case .dailyTargetHours:
            dailyTargetHours = try Preferences.requireFinite(value, key)

        case .theme:
            guard case .string(let raw) = value, let theme = Theme(rawValue: raw) else {
                throw .wrongType(key)
            }
            self.theme = theme

        case .weekStartsOn:
            guard case .number(let raw) = value, raw == 0 || raw == 1 else {
                throw .wrongType(key)
            }
            weekStartsOn = raw == 1 ? .monday : .sunday
        }
    }

    private static func requireBool(
        _ value: PreferenceValue, _ key: PreferenceKey
    ) throws(PreferenceWriteError) -> Bool {
        guard case .bool(let value) = value else { throw .wrongType(key) }
        return value
    }

    private static func requireFinite(
        _ value: PreferenceValue, _ key: PreferenceKey
    ) throws(PreferenceWriteError) -> Double {
        guard case .number(let value) = value, value.isFinite else { throw .wrongType(key) }
        return value
    }
}

// MARK: - Backing store

/// Where a ``DefaultPreferencesStore`` keeps its bytes. Deliberately dumb: it stores and
/// returns untrusted values, and every rule about what those values may be lives in
/// ``Preferences``.
public protocol PreferencesBackend: AnyObject, Sendable {
    func load() -> [String: PreferenceValue]
    func save(_ values: [String: PreferenceValue])
}

/// A backend that never touches disk — for tests, and for a run that must not persist.
public final class InMemoryPreferencesBackend: PreferencesBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PreferenceValue]

    public init(_ values: [String: PreferenceValue] = [:]) {
        self.values = values
    }

    public func load() -> [String: PreferenceValue] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    public func save(_ values: [String: PreferenceValue]) {
        lock.lock()
        defer { lock.unlock() }
        self.values = values
    }
}

/// The shipping backend: one JSON object under one `UserDefaults` key.
///
/// A single blob rather than one default per key, for two reasons. It keeps the stored
/// shape identical to Electron's `preferences.json`, so import and export are the same
/// code path. And it keeps the file honestly untrusted — the whole payload arrives as
/// ``PreferenceValue``s and goes through the same per-key salvage, instead of being read
/// through typed accessors that quietly turn a missing key and a `false` into the same
/// thing.
public final class UserDefaultsPreferencesBackend: PreferencesBackend, @unchecked Sendable {
    public static let defaultKey = "preferences"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsPreferencesBackend.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: PreferenceValue] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: PreferenceValue].self, from: data)
        else {
            // Nothing stored, or bytes we cannot parse. Either way there is no per-key
            // salvage to do and the caller's fallback — the defaults — is the answer.
            return [:]
        }
        return values
    }

    public func save(_ values: [String: PreferenceValue]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Store

/// Cancels a change subscription. Calling it twice is harmless.
public typealias PreferencesUnsubscribe = @Sendable () -> Void

public protocol PreferencesStore: AnyObject, Sendable {
    /// A complete, in-range set. Never fails; a store full of nonsense reads as defaults.
    func getAll() -> Preferences

    /// One value, sanitised exactly as ``getAll()`` would have returned it.
    func value<Value>(_ keyPath: KeyPath<Preferences, Value>) -> Value

    /// Writes one preference and returns the resulting full set.
    @discardableResult
    func set<Value>(_ keyPath: WritableKeyPath<Preferences, Value>, to value: Value) -> Preferences

    /// Writes one untrusted value by key — the path a UI or an IPC-shaped caller takes.
    @discardableResult
    func write(_ key: PreferenceKey, _ value: PreferenceValue) throws(PreferenceWriteError) -> Preferences

    /// As ``write(_:_:)``, rejecting a key that names no preference at all.
    @discardableResult
    func write(rawKey: String, _ value: PreferenceValue) throws(PreferenceWriteError) -> Preferences

    /// Restores every preference to its default.
    @discardableResult
    func reset() -> Preferences

    /// Every successful write notifies every listener, so each surface can re-theme,
    /// show or hide the mini window, reconcile the login item and re-stamp today's
    /// target from one signal.
    func onChange(_ listener: @escaping @Sendable (Preferences) -> Void) -> PreferencesUnsubscribe
}

public final class DefaultPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let backend: PreferencesBackend
    private let defaults: Preferences

    /// Guards `listeners`.
    private let lock = NSLock()
    /// Serialises a whole read-modify-write. Every mutation reads the current set,
    /// changes one key and writes the complete set back, so two concurrent writers
    /// sharing one read would each write a full set and the loser's key would vanish —
    /// while its `set` still returned, and announced, the value it thought it stored.
    /// The Electron original could not produce that: its main process is one thread.
    private let writeLock = NSLock()
    /// Registration order, so listeners are notified in the order they subscribed.
    /// A dictionary's values have no defined order and Swift seeds its hashing per
    /// process, so the order would otherwise vary between two runs of the same binary.
    private var listeners: [(id: Int, callback: @Sendable (Preferences) -> Void)] = []
    private var nextListenerID = 0

    /// - Parameters:
    ///   - backend: where the bytes live.
    ///   - defaults: the set every malformed or missing key falls back to. Overridable so
    ///     a platform can move a default without redefining the rest.
    public init(backend: PreferencesBackend, defaults: Preferences = .defaults) {
        self.backend = backend
        self.defaults = defaults
    }

    public func getAll() -> Preferences {
        Preferences.sanitized(raw: backend.load(), fallback: defaults)
    }

    public func value<Value>(_ keyPath: KeyPath<Preferences, Value>) -> Value {
        getAll()[keyPath: keyPath]
    }

    @discardableResult
    public func set<Value>(
        _ keyPath: WritableKeyPath<Preferences, Value>, to value: Value
    ) -> Preferences {
        // A key-path write cannot fail — only the untrusted `write` path can.
        try! mutate { draft throws(PreferenceWriteError) in
            draft[keyPath: keyPath] = value
        }
    }

    @discardableResult
    public func write(
        _ key: PreferenceKey, _ value: PreferenceValue
    ) throws(PreferenceWriteError) -> Preferences {
        try mutate { draft throws(PreferenceWriteError) in
            try draft.apply(key, value)
        }
    }

    @discardableResult
    public func write(
        rawKey: String, _ value: PreferenceValue
    ) throws(PreferenceWriteError) -> Preferences {
        guard let key = PreferenceKey(rawValue: rawKey) else {
            throw .unknownKey(rawKey)
        }
        return try write(key, value)
    }

    @discardableResult
    public func reset() -> Preferences {
        writeLock.lock()
        let next = defaults.sanitized(fallback: defaults)
        backend.save(next.rawValues)
        writeLock.unlock()
        notify(next)
        return next
    }

    /// Reads, applies `change`, sanitises and writes back — all under one lock, so a
    /// concurrent writer cannot read the same starting set and overwrite the result.
    ///
    /// A `change` that throws writes nothing and notifies nobody: a refused write must
    /// leave the store exactly as it was.
    ///
    /// Listeners are notified after the lock is released, so a listener that writes a
    /// preference of its own cannot deadlock.
    private func mutate(
        _ change: (inout Preferences) throws(PreferenceWriteError) -> Void
    ) throws(PreferenceWriteError) -> Preferences {
        writeLock.lock()
        let current = getAll()
        var draft = current
        do throws(PreferenceWriteError) {
            try change(&draft)
        } catch {
            writeLock.unlock()
            throw error
        }
        // Falling back to `current` rather than the defaults: a rejected value must
        // cost the user the write, not the setting they already had.
        let next = draft.sanitized(fallback: current)
        backend.save(next.rawValues)
        writeLock.unlock()

        notify(next)
        return next
    }

    public func onChange(
        _ listener: @escaping @Sendable (Preferences) -> Void
    ) -> PreferencesUnsubscribe {
        lock.lock()
        let id = nextListenerID
        nextListenerID += 1
        listeners.append((id: id, callback: listener))
        lock.unlock()

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.listeners.removeAll { $0.id == id }
            self.lock.unlock()
        }
    }

    private func notify(_ prefs: Preferences) {
        // Copied before the callbacks run so a listener that unsubscribes itself cannot
        // disturb the iteration, and so no listener is called while the lock is held.
        lock.lock()
        let current = listeners.map(\.callback)
        lock.unlock()

        for listener in current {
            listener(prefs)
        }
    }
}
