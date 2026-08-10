import Foundation
import Testing

import DeyleeKit

/// Ported from `src/main/store/preferences.ts`, which has no TypeScript test file — the
/// cases below are written from the source's rules and the spec's §7 table.
///
/// Nothing here does calendar maths, so no suite pins a timezone.

// MARK: - Helpers

/// A change-listener recorder. Named with the module prefix so it cannot collide with
/// another port's test helpers.
final class PreferencesTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Preferences] = []

    func record(_ prefs: Preferences) {
        lock.lock()
        received.append(prefs)
        lock.unlock()
    }

    var all: [Preferences] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var count: Int { all.count }
    var last: Preferences? { all.last }
}

private func preferencesTestStore(
    _ raw: [String: PreferenceValue] = [:],
    defaults: Preferences = .defaults
) -> (DefaultPreferencesStore, InMemoryPreferencesBackend) {
    let backend = InMemoryPreferencesBackend(raw)
    return (DefaultPreferencesStore(backend: backend, defaults: defaults), backend)
}

// MARK: - Defaults

@Suite struct PreferencesDefaultsTests {
    @Test func macOSDefaultsMatchTheSpecTable() {
        let d = Preferences.defaults
        #expect(d.launchAtLogin == false)
        #expect(d.showMiniWindow == false)
        #expect(d.idleDetectionEnabled == true)
        #expect(d.idleThresholdMinutes == 10)
        #expect(d.autoPauseOnSleep == true)
        #expect(d.autoPauseOnLock == false)
        #expect(d.dailyTargetHours == 8)
        #expect(d.reminderEnabled == false)
        #expect(d.reminderHour == 17)
        #expect(d.reminderMinute == 30)
        #expect(d.theme == .system)
        #expect(d.weekStartsOn == .monday)
        #expect(d.updateCheckEnabled == true)
    }

    @Test func emptyStorageReadsAsTheDefaults() {
        #expect(Preferences.sanitized(raw: [:]) == .defaults)
    }

    @Test func defaultsAreAlreadyInRange() {
        #expect(Preferences.defaults.sanitized() == .defaults)
    }

    @Test func targetMinutesIsRoundedHoursTimesSixty() {
        var prefs = Preferences.defaults
        #expect(prefs.targetMinutes == 480)
        prefs.dailyTargetHours = 7.5
        #expect(prefs.targetMinutes == 450)
        prefs.dailyTargetHours = 7.51
        #expect(prefs.targetMinutes == 451)
        prefs.dailyTargetHours = 0
        #expect(prefs.targetMinutes == 0)
    }

    @Test func targetMinutesReclampsAHandBuiltValue() {
        var prefs = Preferences.defaults
        prefs.dailyTargetHours = 99
        #expect(prefs.targetMinutes == 24 * 60)
        prefs.dailyTargetHours = .nan
        #expect(prefs.targetMinutes == 480)
        prefs.dailyTargetHours = -3
        #expect(prefs.targetMinutes == 0)
    }
}

// MARK: - Coercion

@Suite struct PreferencesCoercionTests {
    @Test func boolTakesOnlyRealBooleans() {
        #expect(PreferenceCoercion.bool(.bool(true), fallback: false) == true)
        #expect(PreferenceCoercion.bool(.bool(false), fallback: true) == false)
        #expect(PreferenceCoercion.bool(.number(1), fallback: false) == false)
        #expect(PreferenceCoercion.bool(.number(0), fallback: true) == true)
        #expect(PreferenceCoercion.bool(.string("true"), fallback: false) == false)
        #expect(PreferenceCoercion.bool(.other, fallback: true) == true)
        #expect(PreferenceCoercion.bool(nil, fallback: true) == true)
    }

    @Test func numberInRangeClampsWithoutRounding() {
        #expect(PreferenceCoercion.numberInRange(.number(7.5), min: 0, max: 24, fallback: 8) == 7.5)
        #expect(PreferenceCoercion.numberInRange(.number(-1), min: 0, max: 24, fallback: 8) == 0)
        #expect(PreferenceCoercion.numberInRange(.number(25), min: 0, max: 24, fallback: 8) == 24)
        #expect(PreferenceCoercion.numberInRange(.number(0), min: 0, max: 24, fallback: 8) == 0)
        #expect(PreferenceCoercion.numberInRange(.number(24), min: 0, max: 24, fallback: 8) == 24)
    }

    @Test func numberInRangeRejectsNonFiniteAndNonNumbers() {
        #expect(PreferenceCoercion.numberInRange(.number(.nan), min: 0, max: 24, fallback: 8) == 8)
        #expect(PreferenceCoercion.numberInRange(.number(.infinity), min: 0, max: 24, fallback: 8) == 8)
        #expect(
            PreferenceCoercion.numberInRange(.number(-.infinity), min: 0, max: 24, fallback: 8) == 8)
        #expect(PreferenceCoercion.numberInRange(.string("7"), min: 0, max: 24, fallback: 8) == 8)
        #expect(PreferenceCoercion.numberInRange(.bool(true), min: 0, max: 24, fallback: 8) == 8)
        #expect(PreferenceCoercion.numberInRange(nil, min: 0, max: 24, fallback: 8) == 8)
    }

    @Test func integerInRangeRoundsThenClamps() {
        #expect(PreferenceCoercion.integerInRange(.number(10.4), min: 1, max: 240, fallback: 10) == 10)
        #expect(PreferenceCoercion.integerInRange(.number(10.5), min: 1, max: 240, fallback: 10) == 11)
        #expect(PreferenceCoercion.integerInRange(.number(0), min: 1, max: 240, fallback: 10) == 1)
        #expect(PreferenceCoercion.integerInRange(.number(241), min: 1, max: 240, fallback: 10) == 240)
        // Rounded first: 240.4 lands on 240 rather than being pushed out of range.
        #expect(
            PreferenceCoercion.integerInRange(.number(240.4), min: 1, max: 240, fallback: 10) == 240)
    }

    @Test func integerInRangeRoundsHalvesTheWayJavaScriptDoes() {
        // Math.round rounds .5 towards +Infinity, so -2.5 is -2, not -3.
        #expect(PreferenceCoercion.integerInRange(.number(-2.5), min: -100, max: 100, fallback: 0) == -2)
        #expect(PreferenceCoercion.integerInRange(.number(2.5), min: -100, max: 100, fallback: 0) == 3)
        #expect(PreferenceCoercion.integerInRange(.number(-0.5), min: -100, max: 100, fallback: 0) == 0)
        #expect(PreferenceCoercion.integerInRange(.number(-1.5), min: -100, max: 100, fallback: 0) == -1)
    }

    @Test func integerInRangeSurvivesValuesFarOutsideIntsRange() {
        #expect(PreferenceCoercion.integerInRange(.number(1e300), min: 1, max: 240, fallback: 10) == 240)
        #expect(PreferenceCoercion.integerInRange(.number(-1e300), min: 1, max: 240, fallback: 10) == 1)
    }

    @Test func integerInRangeRejectsNonFiniteAndNonNumbers() {
        #expect(PreferenceCoercion.integerInRange(.number(.nan), min: 1, max: 240, fallback: 10) == 10)
        #expect(
            PreferenceCoercion.integerInRange(.number(.infinity), min: 1, max: 240, fallback: 10) == 10)
        #expect(PreferenceCoercion.integerInRange(.string("30"), min: 1, max: 240, fallback: 10) == 10)
        #expect(PreferenceCoercion.integerInRange(.bool(false), min: 1, max: 240, fallback: 10) == 10)
        #expect(PreferenceCoercion.integerInRange(nil, min: 1, max: 240, fallback: 10) == 10)
    }

    @Test func themeTakesOnlyTheThreeLiterals() {
        #expect(PreferenceCoercion.theme(.string("system"), fallback: .dark) == .system)
        #expect(PreferenceCoercion.theme(.string("light"), fallback: .dark) == .light)
        #expect(PreferenceCoercion.theme(.string("dark"), fallback: .system) == .dark)
        #expect(PreferenceCoercion.theme(.string("Dark"), fallback: .system) == .system)
        #expect(PreferenceCoercion.theme(.string(""), fallback: .light) == .light)
        #expect(PreferenceCoercion.theme(.number(1), fallback: .light) == .light)
        #expect(PreferenceCoercion.theme(.other, fallback: .light) == .light)
        #expect(PreferenceCoercion.theme(nil, fallback: .light) == .light)
    }

    @Test func weekStartBendsAnyNumberIntoTheTwoWeeksThatExist() {
        #expect(PreferenceCoercion.weekStart(.number(0), fallback: .monday) == .sunday)
        #expect(PreferenceCoercion.weekStart(.number(1), fallback: .sunday) == .monday)
        #expect(PreferenceCoercion.weekStart(.number(7), fallback: .sunday) == .monday)
        #expect(PreferenceCoercion.weekStart(.number(0.6), fallback: .sunday) == .monday)
        #expect(PreferenceCoercion.weekStart(.number(0.4), fallback: .monday) == .sunday)
        #expect(PreferenceCoercion.weekStart(.number(-3), fallback: .monday) == .sunday)
    }

    @Test func weekStartRejectsNonNumbers() {
        #expect(PreferenceCoercion.weekStart(.string("1"), fallback: .monday) == .monday)
        #expect(PreferenceCoercion.weekStart(.bool(true), fallback: .sunday) == .sunday)
        #expect(PreferenceCoercion.weekStart(.number(.nan), fallback: .monday) == .monday)
        #expect(PreferenceCoercion.weekStart(.other, fallback: .sunday) == .sunday)
        #expect(PreferenceCoercion.weekStart(nil, fallback: .monday) == .monday)
    }
}

// MARK: - Sanitising a whole set

@Suite struct PreferencesSanitiseTests {
    @Test func everyValidValueSurvivesUntouched() {
        let raw: [String: PreferenceValue] = [
            "launchAtLogin": .bool(true),
            "showMiniWindow": .bool(true),
            "idleDetectionEnabled": .bool(false),
            "idleThresholdMinutes": .number(25),
            "autoPauseOnSleep": .bool(false),
            "autoPauseOnLock": .bool(true),
            "dailyTargetHours": .number(7.5),
            "reminderEnabled": .bool(true),
            "reminderHour": .number(9),
            "reminderMinute": .number(0),
            "theme": .string("dark"),
            "weekStartsOn": .number(0),
            "updateCheckEnabled": .bool(false),
        ]

        let prefs = Preferences.sanitized(raw: raw)
        #expect(prefs.launchAtLogin == true)
        #expect(prefs.showMiniWindow == true)
        #expect(prefs.idleDetectionEnabled == false)
        #expect(prefs.idleThresholdMinutes == 25)
        #expect(prefs.autoPauseOnSleep == false)
        #expect(prefs.autoPauseOnLock == true)
        #expect(prefs.dailyTargetHours == 7.5)
        #expect(prefs.reminderEnabled == true)
        #expect(prefs.reminderHour == 9)
        #expect(prefs.reminderMinute == 0)
        #expect(prefs.theme == .dark)
        #expect(prefs.weekStartsOn == .sunday)
        #expect(prefs.updateCheckEnabled == false)
    }

    @Test func oneMalformedKeyNeverCostsTheRest() {
        let raw: [String: PreferenceValue] = [
            "theme": .number(3),
            "idleThresholdMinutes": .string("lots"),
            "dailyTargetHours": .number(6.25),
            "reminderEnabled": .bool(true),
            "reminderHour": .number(9),
        ]

        let prefs = Preferences.sanitized(raw: raw)
        #expect(prefs.theme == .system)
        #expect(prefs.idleThresholdMinutes == 10)
        #expect(prefs.dailyTargetHours == 6.25)
        #expect(prefs.reminderEnabled == true)
        #expect(prefs.reminderHour == 9)
        #expect(prefs.reminderMinute == 30)
    }

    @Test func eachKeyClampsIntoItsOwnRange() {
        let raw: [String: PreferenceValue] = [
            "idleThresholdMinutes": .number(9000),
            "dailyTargetHours": .number(-4),
            "reminderHour": .number(24),
            "reminderMinute": .number(60),
        ]

        let prefs = Preferences.sanitized(raw: raw)
        #expect(prefs.idleThresholdMinutes == 240)
        #expect(prefs.dailyTargetHours == 0)
        #expect(prefs.reminderHour == 23)
        #expect(prefs.reminderMinute == 59)
    }

    @Test func fractionalTargetsAreKeptWhileIntegerPrefsAreRounded() {
        let raw: [String: PreferenceValue] = [
            "dailyTargetHours": .number(7.75),
            "idleThresholdMinutes": .number(14.6),
            "reminderHour": .number(16.5),
            "reminderMinute": .number(29.49),
        ]

        let prefs = Preferences.sanitized(raw: raw)
        #expect(prefs.dailyTargetHours == 7.75)
        #expect(prefs.idleThresholdMinutes == 15)
        #expect(prefs.reminderHour == 17)
        #expect(prefs.reminderMinute == 29)
    }

    @Test func aNonDefaultFallbackIsUsedPerKey() {
        var fallback = Preferences.defaults
        fallback.showMiniWindow = true
        fallback.dailyTargetHours = 6
        fallback.theme = .dark

        let prefs = Preferences.sanitized(raw: ["theme": .string("nope")], fallback: fallback)
        #expect(prefs.showMiniWindow == true)
        #expect(prefs.dailyTargetHours == 6)
        #expect(prefs.theme == .dark)
    }

    @Test func unknownAndPlatformIgnoredKeysAreSkipped() {
        let raw: [String: PreferenceValue] = [
            "theme": .string("light"),
            "miniWindowPositions": .other,
            "trayFallbackNoticeShown": .bool(true),
            "hackedInByHand": .string("whatever"),
        ]

        let prefs = Preferences.sanitized(raw: raw)
        #expect(prefs.theme == .light)
        #expect(prefs == { var p = Preferences.defaults; p.theme = .light; return p }())
    }

    @Test func ignoredElectronKeysAreDocumentedAsSuch() {
        #expect(PreferenceKey.ignoredElectronKeys == ["miniWindowPositions", "trayFallbackNoticeShown"])
        for ignored in PreferenceKey.ignoredElectronKeys {
            #expect(PreferenceKey(rawValue: ignored) == nil)
        }
    }

    @Test func everyKeyIsCoveredByTheSanitiser() {
        // A key added to the enum but forgotten in `sanitized(raw:)` would read back as
        // its default no matter what is stored; this catches that.
        var flipped = Preferences.defaults
        flipped.launchAtLogin = true
        flipped.showMiniWindow = true
        flipped.idleDetectionEnabled = false
        flipped.idleThresholdMinutes = 33
        flipped.autoPauseOnSleep = false
        flipped.autoPauseOnLock = true
        flipped.dailyTargetHours = 5.5
        flipped.reminderEnabled = true
        flipped.reminderHour = 6
        flipped.reminderMinute = 7
        flipped.theme = .light
        flipped.weekStartsOn = .sunday
        flipped.updateCheckEnabled = false
        flipped.screenCaptureEnabled = true
        flipped.screenCaptureIntervalMinutes = 3
        flipped.screenCaptureRetentionDays = 21

        #expect(Preferences.sanitized(raw: flipped.rawValues) == flipped)
        #expect(flipped.rawValues.count == PreferenceKey.allCases.count)
        for key in PreferenceKey.allCases {
            #expect(flipped.rawValues[key.rawValue] != nil)
        }

        // The two loops below are what make this test hard to fool, and they exist
        // because the version above was fooled. `screenCaptureEnabled` was added to the
        // enum, to `rawValues` and to `apply`, but not to `sanitized(raw:)` — so every
        // write saved correctly and every read rebuilt it from the default. The window
        // flashed "Saved" and the switch stayed off. This test passed throughout, because
        // a key nobody remembers to flip above sits at its default on both sides of the
        // comparison and matches itself.
        let defaults = Preferences.defaults.rawValues
        for key in PreferenceKey.allCases {
            #expect(
                flipped.rawValues[key.rawValue] != defaults[key.rawValue],
                "\(key.rawValue) is not changed from its default above, so nothing here can tell whether the sanitiser reads it"
            )
        }
        // Each key on its own: change only that one and the result must stop being the
        // defaults. A key the sanitiser ignores cannot move the answer.
        for key in PreferenceKey.allCases {
            var raw = defaults
            raw[key.rawValue] = flipped.rawValues[key.rawValue]
            #expect(
                Preferences.sanitized(raw: raw) != Preferences.defaults,
                "\(key.rawValue) is never read by sanitized(raw:), so a stored value for it is silently discarded"
            )
        }
    }

    @Test func sanitisingATypedDraftClampsAndRepairsNonFiniteHours() {
        var draft = Preferences.defaults
        draft.idleThresholdMinutes = 9000
        draft.reminderMinute = -5
        draft.dailyTargetHours = .nan

        var current = Preferences.defaults
        current.dailyTargetHours = 6.5

        let clean = draft.sanitized(fallback: current)
        #expect(clean.idleThresholdMinutes == 240)
        #expect(clean.reminderMinute == 0)
        #expect(clean.dailyTargetHours == 6.5)
    }
}

// MARK: - Electron JSON

@Suite struct PreferencesElectronJSONTests {
    @Test func decodesARealPreferencesFile() throws {
        let json = """
            {
              "launchAtLogin": true,
              "showMiniWindow": true,
              "idleDetectionEnabled": true,
              "idleThresholdMinutes": 15,
              "autoPauseOnSleep": true,
              "autoPauseOnLock": true,
              "dailyTargetHours": 7.5,
              "reminderEnabled": true,
              "reminderHour": 18,
              "reminderMinute": 45,
              "theme": "dark",
              "weekStartsOn": 0,
              "miniWindowPositions": { "12345": { "x": 100, "y": 220 } },
              "trayFallbackNoticeShown": true,
              "updateCheckEnabled": false
            }
            """
        let data = try #require(json.data(using: .utf8))

        let prefs = Preferences.fromElectronJSON(data)
        #expect(prefs.launchAtLogin == true)
        #expect(prefs.showMiniWindow == true)
        #expect(prefs.idleThresholdMinutes == 15)
        #expect(prefs.autoPauseOnLock == true)
        #expect(prefs.dailyTargetHours == 7.5)
        #expect(prefs.reminderEnabled == true)
        #expect(prefs.reminderHour == 18)
        #expect(prefs.reminderMinute == 45)
        #expect(prefs.theme == .dark)
        #expect(prefs.weekStartsOn == .sunday)
        #expect(prefs.updateCheckEnabled == false)
    }

    @Test func aPartialFileFillsTheGapsFromTheDefaults() throws {
        let data = try #require(#"{ "theme": "light", "dailyTargetHours": 6 }"#.data(using: .utf8))

        let prefs = Preferences.fromElectronJSON(data)
        #expect(prefs.theme == .light)
        #expect(prefs.dailyTargetHours == 6)
        #expect(prefs.idleThresholdMinutes == 10)
        #expect(prefs.updateCheckEnabled == true)
    }

    @Test func nullsAndNestedShapesFallBackWithoutTakingTheFileDown() throws {
        let json = """
            {
              "theme": null,
              "idleThresholdMinutes": [1, 2],
              "reminderHour": { "hour": 9 },
              "autoPauseOnLock": true
            }
            """
        let data = try #require(json.data(using: .utf8))

        let prefs = Preferences.fromElectronJSON(data)
        #expect(prefs.theme == .system)
        #expect(prefs.idleThresholdMinutes == 10)
        #expect(prefs.reminderHour == 17)
        #expect(prefs.autoPauseOnLock == true)
    }

    @Test func numbersWrittenAsStringsAreNotNumbers() throws {
        let data = try #require(
            #"{ "idleThresholdMinutes": "15", "dailyTargetHours": "7.5", "weekStartsOn": "0" }"#
                .data(using: .utf8))

        let prefs = Preferences.fromElectronJSON(data)
        #expect(prefs.idleThresholdMinutes == 10)
        #expect(prefs.dailyTargetHours == 8)
        #expect(prefs.weekStartsOn == .monday)
    }

    @Test func aFileThatIsNotAJSONObjectYieldsTheFallbackWhole() throws {
        var fallback = Preferences.defaults
        fallback.theme = .dark

        for text in ["not json at all", "[1, 2, 3]", "\"a string\"", "", "{ \"theme\": "] {
            let data = try #require(text.data(using: .utf8))
            #expect(Preferences.fromElectronJSON(data, fallback: fallback) == fallback)
        }
    }

    @Test func encodingRoundTripsThroughTheSameShape() throws {
        var prefs = Preferences.defaults
        prefs.theme = .light
        prefs.dailyTargetHours = 7.25
        prefs.weekStartsOn = .sunday
        prefs.reminderHour = 8
        prefs.launchAtLogin = true

        let data = try prefs.electronJSON()
        #expect(Preferences.fromElectronJSON(data) == prefs)
    }

    @Test func encodingNeverWritesTheIgnoredKeys() throws {
        let data = try Preferences.defaults.electronJSON()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("miniWindowPositions"))
        #expect(!text.contains("trayFallbackNoticeShown"))
    }
}

// MARK: - Store reads and writes

@Suite struct PreferencesStoreTests {
    @Test func anEmptyStoreReadsAsTheDefaults() {
        let (store, _) = preferencesTestStore()
        #expect(store.getAll() == .defaults)
    }

    @Test func platformDefaultsOverrideTheCompiledInOnes() {
        var platform = Preferences.defaults
        platform.showMiniWindow = true
        let (store, _) = preferencesTestStore(defaults: platform)

        #expect(store.getAll().showMiniWindow == true)
        #expect(store.value(\.idleThresholdMinutes) == 10)
    }

    @Test func readingClampsWhatIsAlreadyOnDisk() {
        let (store, _) = preferencesTestStore([
            "idleThresholdMinutes": .number(9000),
            "dailyTargetHours": .number(99),
            "theme": .string("neon"),
        ])

        let prefs = store.getAll()
        #expect(prefs.idleThresholdMinutes == 240)
        #expect(prefs.dailyTargetHours == 24)
        #expect(prefs.theme == .system)
    }

    @Test func valueReadsASingleSanitisedKey() {
        let (store, _) = preferencesTestStore(["reminderHour": .number(30)])
        #expect(store.value(\.reminderHour) == 23)
        #expect(store.value(\.theme) == .system)
    }

    @Test func writingPersistsAndReturnsTheFullSet() {
        let (store, backend) = preferencesTestStore()

        let next = store.set(\.theme, to: .dark)
        #expect(next.theme == .dark)
        #expect(store.getAll().theme == .dark)
        #expect(backend.load()["theme"] == .string("dark"))
        #expect(next.idleThresholdMinutes == 10)
    }

    @Test func writingClampsBeforeItStores() {
        let (store, backend) = preferencesTestStore()

        #expect(store.set(\.idleThresholdMinutes, to: 9000).idleThresholdMinutes == 240)
        #expect(backend.load()["idleThresholdMinutes"] == .number(240))
        #expect(store.set(\.dailyTargetHours, to: -2).dailyTargetHours == 0)
        #expect(store.set(\.reminderMinute, to: 61).reminderMinute == 59)
    }

    @Test func aRejectedValueCostsTheWriteNotTheSettingAlreadyHeld() {
        let (store, _) = preferencesTestStore()
        store.set(\.dailyTargetHours, to: 6.5)

        // Not-a-number is the one value the typed API can still smuggle in; it must fall
        // back to what the user already had, not to the compiled-in default.
        #expect(store.set(\.dailyTargetHours, to: .nan).dailyTargetHours == 6.5)
        #expect(store.getAll().dailyTargetHours == 6.5)
    }

    @Test func writingOneKeyRepairsAMalformedNeighbourRatherThanKeepingIt() {
        let (store, backend) = preferencesTestStore([
            "theme": .number(3),
            "reminderHour": .number(9),
        ])

        store.set(\.reminderMinute, to: 15)
        #expect(backend.load()["theme"] == .string("system"))
        #expect(backend.load()["reminderHour"] == .number(9))
        #expect(backend.load()["reminderMinute"] == .number(15))
    }

    @Test func resetRestoresThePlatformDefaults() {
        var platform = Preferences.defaults
        platform.showMiniWindow = true
        let (store, _) = preferencesTestStore(defaults: platform)

        store.set(\.theme, to: .dark)
        store.set(\.showMiniWindow, to: false)

        #expect(store.reset() == platform)
        #expect(store.getAll() == platform)
    }
}

// MARK: - Untrusted writes by key

@Suite struct PreferencesKeyedWriteTests {
    @Test func aBooleanKeyTakesOnlyABoolean() throws {
        let (store, _) = preferencesTestStore()

        #expect(try store.write(.showMiniWindow, .bool(true)).showMiniWindow == true)
        #expect(throws: PreferenceWriteError.wrongType(.showMiniWindow)) {
            try store.write(.showMiniWindow, .number(1))
        }
        #expect(throws: PreferenceWriteError.wrongType(.showMiniWindow)) {
            try store.write(.showMiniWindow, .string("true"))
        }
        #expect(store.getAll().showMiniWindow == true)
    }

    @Test func aNumericKeyTakesOnlyAFiniteNumberAndIsThenClamped() throws {
        let (store, _) = preferencesTestStore()

        #expect(try store.write(.idleThresholdMinutes, .number(9000)).idleThresholdMinutes == 240)
        #expect(try store.write(.idleThresholdMinutes, .number(0)).idleThresholdMinutes == 1)
        #expect(try store.write(.idleThresholdMinutes, .number(14.6)).idleThresholdMinutes == 15)
        #expect(try store.write(.dailyTargetHours, .number(7.5)).dailyTargetHours == 7.5)
        #expect(try store.write(.dailyTargetHours, .number(1e300)).dailyTargetHours == 24)

        #expect(throws: PreferenceWriteError.wrongType(.idleThresholdMinutes)) {
            try store.write(.idleThresholdMinutes, .string("30"))
        }
        #expect(throws: PreferenceWriteError.wrongType(.dailyTargetHours)) {
            try store.write(.dailyTargetHours, .number(.nan))
        }
        #expect(throws: PreferenceWriteError.wrongType(.dailyTargetHours)) {
            try store.write(.dailyTargetHours, .number(.infinity))
        }
    }

    @Test func themeTakesOnlyTheThreeLiterals() throws {
        let (store, _) = preferencesTestStore()

        #expect(try store.write(.theme, .string("dark")).theme == .dark)
        #expect(throws: PreferenceWriteError.wrongType(.theme)) {
            try store.write(.theme, .string("Dark"))
        }
        #expect(throws: PreferenceWriteError.wrongType(.theme)) {
            try store.write(.theme, .number(1))
        }
        #expect(store.getAll().theme == .dark)
    }

    @Test func writingWeekStartIsStricterThanReadingIt() throws {
        let (store, _) = preferencesTestStore()

        #expect(try store.write(.weekStartsOn, .number(0)).weekStartsOn == .sunday)
        #expect(try store.write(.weekStartsOn, .number(1)).weekStartsOn == .monday)
        // A stored 7 reads back as Monday, but a *write* of 7 is a mistake worth telling
        // the user about rather than bending into range.
        #expect(throws: PreferenceWriteError.wrongType(.weekStartsOn)) {
            try store.write(.weekStartsOn, .number(7))
        }
        #expect(throws: PreferenceWriteError.wrongType(.weekStartsOn)) {
            try store.write(.weekStartsOn, .number(0.6))
        }
        #expect(throws: PreferenceWriteError.wrongType(.weekStartsOn)) {
            try store.write(.weekStartsOn, .string("1"))
        }
        #expect(Preferences.sanitized(raw: ["weekStartsOn": .number(7)]).weekStartsOn == .monday)
    }

    @Test func anUnknownKeyIsRefusedRatherThanStored() throws {
        let (store, backend) = preferencesTestStore()

        #expect(throws: PreferenceWriteError.unknownKey("wat")) {
            try store.write(rawKey: "wat", .bool(true))
        }
        #expect(backend.load()["wat"] == nil)
        #expect(backend.load().isEmpty)
    }

    @Test func thePlatformIgnoredKeysAreUnknownToWrites() {
        let (store, _) = preferencesTestStore()

        #expect(throws: PreferenceWriteError.unknownKey("trayFallbackNoticeShown")) {
            try store.write(rawKey: "trayFallbackNoticeShown", .bool(true))
        }
        #expect(throws: PreferenceWriteError.unknownKey("miniWindowPositions")) {
            try store.write(rawKey: "miniWindowPositions", .other)
        }
    }

    @Test func aKnownKeyByNameGoesThroughTheSameNarrowing() throws {
        let (store, _) = preferencesTestStore()

        #expect(try store.write(rawKey: "reminderMinute", .number(45)).reminderMinute == 45)
        #expect(throws: PreferenceWriteError.wrongType(.reminderMinute)) {
            try store.write(rawKey: "reminderMinute", .bool(true))
        }
    }

    @Test func aRefusedWriteLeavesTheStoredSetExactlyAsItWas() {
        let (store, backend) = preferencesTestStore()
        store.set(\.theme, to: .light)
        let before = backend.load()

        #expect(throws: PreferenceWriteError.self) { try store.write(.theme, .string("chartreuse")) }
        #expect(backend.load() == before)
        #expect(store.getAll().theme == .light)
    }

    @Test func theRefusalMessageIsTheOneTheUIShows() {
        #expect(
            PreferenceWriteError.unknownKey("wat").message
                == "Could not save \"wat\": unknown preference, or wrong type.")
        #expect(
            PreferenceWriteError.wrongType(.dailyTargetHours).message
                == "Could not save \"dailyTargetHours\": unknown preference, or wrong type.")
    }

    @Test func applyingToADraftLeavesTheOtherKeysAlone() throws {
        var draft = Preferences.defaults
        draft.theme = .dark
        try draft.apply(.reminderHour, .number(6))

        #expect(draft.reminderHour == 6)
        #expect(draft.theme == .dark)
        #expect(draft.idleThresholdMinutes == 10)
    }
}

// MARK: - Change notification

@Suite struct PreferencesChangeTests {
    @Test func everySuccessfulWriteNotifies() {
        let (store, _) = preferencesTestStore()
        let recorder = PreferencesTestRecorder()
        _ = store.onChange { recorder.record($0) }

        store.set(\.theme, to: .dark)
        store.set(\.showMiniWindow, to: true)

        #expect(recorder.count == 2)
        #expect(recorder.all.first?.theme == .dark)
        #expect(recorder.last?.showMiniWindow == true)
        #expect(recorder.last?.theme == .dark)
    }

    @Test func aRefusedWriteNotifiesNobody() {
        let (store, _) = preferencesTestStore()
        let recorder = PreferencesTestRecorder()
        _ = store.onChange { recorder.record($0) }

        #expect(throws: PreferenceWriteError.self) { try store.write(.theme, .number(2)) }
        #expect(recorder.count == 0)
    }

    @Test func resetNotifies() {
        let (store, _) = preferencesTestStore()
        let recorder = PreferencesTestRecorder()
        _ = store.onChange { recorder.record($0) }

        store.reset()
        #expect(recorder.count == 1)
        #expect(recorder.last == .defaults)
    }

    @Test func everyListenerIsTold() {
        let (store, _) = preferencesTestStore()
        let first = PreferencesTestRecorder()
        let second = PreferencesTestRecorder()
        _ = store.onChange { first.record($0) }
        _ = store.onChange { second.record($0) }

        store.set(\.reminderEnabled, to: true)

        #expect(first.count == 1)
        #expect(second.count == 1)
    }

    @Test func unsubscribingStopsTheCallbacks() {
        let (store, _) = preferencesTestStore()
        let recorder = PreferencesTestRecorder()
        let unsubscribe = store.onChange { recorder.record($0) }

        store.set(\.theme, to: .dark)
        unsubscribe()
        store.set(\.theme, to: .light)

        #expect(recorder.count == 1)
        // Cancelling twice is harmless.
        unsubscribe()
        store.set(\.theme, to: .system)
        #expect(recorder.count == 1)
    }

    @Test func aListenerThatUnsubscribesItselfDoesNotDisturbTheOthers() {
        let (store, _) = preferencesTestStore()
        let selfCancelling = PreferencesTestRecorder()
        let other = PreferencesTestRecorder()

        // Boxed so the listener can reach the token that cancels it.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var unsubscribe: PreferencesUnsubscribe?
        }
        let box = Box()
        box.unsubscribe = store.onChange { prefs in
            selfCancelling.record(prefs)
            box.lock.lock()
            let cancel = box.unsubscribe
            box.unsubscribe = nil
            box.lock.unlock()
            cancel?()
        }
        _ = store.onChange { other.record($0) }

        store.set(\.theme, to: .dark)
        store.set(\.theme, to: .light)

        #expect(selfCancelling.count == 1)
        #expect(other.count == 2)
    }
}

// MARK: - Backends

@Suite struct PreferencesBackendTests {
    @Test func theUserDefaultsBackendRoundTripsAWholeSet() throws {
        let suite = "me.faizraza.deylee.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let backend = UserDefaultsPreferencesBackend(defaults: defaults, key: "preferences")
        let store = DefaultPreferencesStore(backend: backend)

        #expect(store.getAll() == .defaults)
        store.set(\.dailyTargetHours, to: 7.5)
        store.set(\.theme, to: .dark)

        let reopened = DefaultPreferencesStore(
            backend: UserDefaultsPreferencesBackend(defaults: defaults, key: "preferences"))
        #expect(reopened.getAll().dailyTargetHours == 7.5)
        #expect(reopened.getAll().theme == .dark)
    }

    @Test func theUserDefaultsBackendSurvivesBytesItCannotParse() throws {
        let suite = "me.faizraza.deylee.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not json".utf8), forKey: "preferences")
        let store = DefaultPreferencesStore(
            backend: UserDefaultsPreferencesBackend(defaults: defaults, key: "preferences"))

        #expect(store.getAll() == .defaults)
        // And a write repairs the store rather than compounding the mess.
        store.set(\.theme, to: .light)
        #expect(store.getAll().theme == .light)
    }

    @Test func theUserDefaultsBackendStoresTheElectronJSONShape() throws {
        let suite = "me.faizraza.deylee.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DefaultPreferencesStore(
            backend: UserDefaultsPreferencesBackend(defaults: defaults, key: "preferences"))
        store.set(\.reminderHour, to: 6)

        let data = try #require(defaults.data(forKey: "preferences"))
        #expect(Preferences.fromElectronJSON(data) == store.getAll())
    }

    @Test func theStoreIsUsableThroughItsProtocol() throws {
        // Every surface holds the store as `any PreferencesStore`, so the whole API has
        // to survive the existential.
        let store: any PreferencesStore = DefaultPreferencesStore(
            backend: InMemoryPreferencesBackend())

        #expect(store.getAll() == .defaults)
        #expect(store.value(\.theme) == .system)
        #expect(store.set(\.theme, to: .dark).theme == .dark)
        #expect(try store.write(.reminderHour, .number(6)).reminderHour == 6)
        #expect(throws: PreferenceWriteError.unknownKey("nope")) {
            try store.write(rawKey: "nope", .bool(true))
        }
        let unsubscribe = store.onChange { _ in }
        unsubscribe()
        #expect(store.reset() == .defaults)
    }

    @Test func anImportedElectronFileCanBeSeededStraightIntoAStore() throws {
        let json = #"{ "theme": "dark", "dailyTargetHours": 7.5, "miniWindowPositions": {} }"#
        let imported = Preferences.fromElectronJSON(try #require(json.data(using: .utf8)))

        let backend = InMemoryPreferencesBackend(imported.rawValues)
        let store = DefaultPreferencesStore(backend: backend)

        #expect(store.getAll() == imported)
        #expect(store.getAll().theme == .dark)
        #expect(store.getAll().dailyTargetHours == 7.5)
    }
}
