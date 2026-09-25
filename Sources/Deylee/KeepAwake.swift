import IOKit.ps
import IOKit.pwr_mgt
import DeyleeKit

/// Keeps the Mac awake while a ``KeepAwakeSession`` says so — what `caffeinate` or
/// KeepingYouAwake do, folded in so one menu-bar app covers both.
///
/// A power assertion rather than a spawned `caffeinate`: it is released by the kernel
/// if the process dies, so a crash never leaves the Mac unable to sleep. It does not
/// touch the HID idle clock, so idle detection still sees an absent user.
@MainActor
final class KeepAwake {
    private let prefs: PreferencesStore
    private(set) var session = KeepAwakeSession()
    private var assertion: IOPMAssertionID?
    /// Whether the held assertion lets the display sleep, so a changed preference
    /// swaps it for the other kind on the next tick.
    private var assertionAllowsDisplaySleep = false

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    /// `minutes <= 0` runs until turned off; `nil` takes the default length.
    func turnOn(minutes: Int? = nil) {
        session.turnOn(minutes: minutes ?? prefs.value(\.keepAwakeDefaultMinutes), now: epochNow())
        apply()
    }

    func turnOff() {
        session.turnOff()
        apply()
    }

    /// Called on the status item's one-second refresh.
    func tick() {
        let followPower = prefs.value(\.keepAwakeOnBattery)
        // ponytail: polls the power source each second rather than subscribing to
        // IOPSNotificationCreateRunLoopSource; one cheap IPC a second, only while the rule is on.
        session.tick(now: epochNow(), onBattery: followPower && Self.onBattery(), followPower: followPower)
        apply()
    }

    private func apply() {
        let allowDisplaySleep = prefs.value(\.keepAwakeAllowDisplaySleep)
        if let id = assertion, !session.isOn || allowDisplaySleep != assertionAllowsDisplaySleep {
            IOPMAssertionRelease(id)
            assertion = nil
        }
        guard session.isOn, assertion == nil else { return }

        // Holding the display awake holds the system awake with it while the lid is open.
        let type = allowDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Deylee: Keep Awake" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertion = id
            assertionAllowsDisplaySleep = allowDisplaySleep
        }
    }

    private static func onBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        return source == kIOPMBatteryPowerKey
    }
}
