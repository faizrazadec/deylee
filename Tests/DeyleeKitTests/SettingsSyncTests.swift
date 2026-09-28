import Foundation
import Testing

import DeyleeKit

/// Settings sync's bookkeeping, against an in-memory preferences store and a throwaway
/// `UserDefaults` suite. No calendar maths, so no suite pins a timezone.
struct SettingsSyncTests {
    private final class Clock: @unchecked Sendable {
        var now: EpochMs = 1_700_000_000_000
    }

    private func make(
        _ stored: [String: PreferenceValue] = [:]
    ) -> (PreferencesStore, SettingsSyncTracker, Clock, UserDefaults) {
        let defaults = UserDefaults(suiteName: "settings-sync-\(UUID())")!
        let store = DefaultPreferencesStore(backend: InMemoryPreferencesBackend(stored))
        let clock = Clock()
        let tracker = SettingsSyncTracker(store: store, defaults: defaults, now: { clock.now })
        return (store, tracker, clock, defaults)
    }

    @Test func screenCaptureAndLaunchAtLoginNeverLeaveTheMac() {
        var prefs = Preferences.defaults
        prefs.screenCaptureEnabled = true
        let payload = SettingsSyncTracker.payload(prefs)
        for key in SettingsSyncTracker.localOnlyKeys {
            #expect(payload[key.rawValue] == nil, "\(key.rawValue) must not be sent")
        }
        #expect(payload["keepAwakeLidClosed"] == .bool(false))

        // Nor can a set from the account switch capture on.
        let merged = SettingsSyncTracker.merging(
            ["screenCaptureEnabled": .bool(true), "launchAtLogin": .bool(true)],
            into: .defaults
        )
        #expect(!merged.screenCaptureEnabled)
        #expect(!merged.launchAtLogin)
    }

    @Test func aPulledSetIsClampedAndABadKeyKeepsTheLocalValue() {
        var local = Preferences.defaults
        local.theme = .dark
        let merged = SettingsSyncTracker.merging(
            ["idleThresholdMinutes": .number(10_000), "theme": .string("purple"),
             "keepAwakeLidClosed": .bool(true), "somethingNew": .bool(true)],
            into: local
        )
        #expect(merged.idleThresholdMinutes == PreferenceLimits.idleThresholdMaxMinutes)
        #expect(merged.theme == .dark)
        #expect(merged.keepAwakeLidClosed)
    }

    @Test func aFreshInstallTakesTheAccountsSet() {
        let (store, tracker, _, _) = make()
        #expect(tracker.current == .init(updatedAt: nil, dirty: false))
        #expect(tracker.pending() == nil)

        tracker.receive(settings: ["theme": .string("dark")], updatedAt: 42)
        #expect(store.value(\.theme) == .dark)
        // Taking the account's set is not a change of our own to send back.
        #expect(tracker.current == .init(updatedAt: 42, dirty: false))
    }

    @Test func aLocalChangeIsSentAndClearedOnceTheAccountHasIt() throws {
        let (store, tracker, clock, _) = make()
        clock.now = 1_000
        try store.write(.theme, .string("light"))
        let pending = try #require(tracker.pending())
        #expect(pending.updatedAt == 1_000)
        #expect(pending.settings["theme"] == .string("light"))
        #expect(pending.settings["screenCaptureEnabled"] == nil)

        tracker.receive(settings: pending.settings, updatedAt: 1_000)
        #expect(tracker.pending() == nil)
    }

    @Test func aLocalOnlyChangeIsNothingToSend() throws {
        let (store, tracker, _, _) = make()
        try store.write(.screenCaptureEnabled, .bool(true))
        try store.write(.settingsSyncEnabled, .bool(false))
        #expect(tracker.pending() == nil)
    }

    @Test func theNewerSideWins() throws {
        let (store, tracker, clock, _) = make()
        clock.now = 2_000
        try store.write(.theme, .string("light"))

        // Older in the account: ours stands and is still owed.
        tracker.receive(settings: ["theme": .string("dark")], updatedAt: 1_000)
        #expect(store.value(\.theme) == .light)
        #expect(tracker.current.dirty)

        // Newer in the account: it wins.
        tracker.receive(settings: ["theme": .string("dark")], updatedAt: 3_000)
        #expect(store.value(\.theme) == .dark)
        #expect(tracker.current == .init(updatedAt: 3_000, dirty: false))
    }

    @Test func settingsChosenBeforeSyncExistedFillAnEmptyAccountButNeverOverwriteOne() {
        let (_, tracker, _, _) = make(["theme": .string("dark")])
        #expect(tracker.current == .init(updatedAt: 0, dirty: true))
        #expect(tracker.pending()?.settings["theme"] == .string("dark"))
    }

    @Test func theBookkeepingSurvivesARelaunch() throws {
        let (store, tracker, clock, defaults) = make()
        clock.now = 5_000
        try store.write(.theme, .string("light"))
        let relaunched = SettingsSyncTracker(store: store, defaults: defaults, now: { 9_999 })
        #expect(relaunched.current == tracker.current)
        #expect(relaunched.pending()?.updatedAt == 5_000)
    }

    @Test func resetPutsSyncedSettingsBackAndIsSentEvenWhenNothingChangedHere() throws {
        let (store, tracker, clock, _) = make()
        try store.write(.screenCaptureEnabled, .bool(true))
        clock.now = 7_000
        tracker.resetToDefaults()
        #expect(tracker.pending()?.updatedAt == 7_000)

        try store.write(.theme, .string("dark"))
        try store.write(.keepAwakeLidClosed, .bool(true))
        clock.now = 8_000
        tracker.resetToDefaults()
        #expect(store.value(\.theme) == Preferences.defaults.theme)
        #expect(!store.value(\.keepAwakeLidClosed))
        #expect(store.value(\.screenCaptureEnabled), "local-only settings are not reset")
        #expect(tracker.pending()?.updatedAt == 8_000)
    }
}
