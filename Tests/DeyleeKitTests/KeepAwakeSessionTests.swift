import Testing

import DeyleeKit

/// Nothing here does calendar maths — a session length is a duration, not a day — so no
/// suite pins a timezone.
struct KeepAwakeSessionTests {
    private let t0: EpochMs = 1_700_000_000_000

    @Test func aTimedSessionEndsOnTheFirstTickPastItsEnd() {
        var session = KeepAwakeSession()
        session.turnOn(minutes: 5, now: t0)
        #expect(session.endsAt == t0 + 5 * 60_000)

        session.tick(now: t0 + 5 * 60_000 - 1, onBattery: false, followPower: false)
        #expect(session.isOn)
        // An hour late, as after a sleep: still ends.
        session.tick(now: t0 + 65 * 60_000, onBattery: false, followPower: false)
        #expect(!session.isOn)
        #expect(session.endsAt == nil)
    }

    @Test func zeroMinutesRunsUntilTurnedOff() {
        var session = KeepAwakeSession()
        session.turnOn(minutes: 0, now: t0)
        session.tick(now: t0 + 1_000 * 60_000, onBattery: false, followPower: false)
        #expect(session.isOn)
        #expect(session.endsAt == nil)
        session.turnOff()
        #expect(!session.isOn)
    }

    @Test func theBatteryRuleActsOnlyOnASwitch() {
        var session = KeepAwakeSession()
        // Launched on the adapter: nothing to switch off, nothing turned on.
        session.tick(now: t0, onBattery: false, followPower: true)
        #expect(!session.isOn)

        session.tick(now: t0 + 1, onBattery: true, followPower: true)
        #expect(session.isOn)
        #expect(session.endsAt == nil)

        // Turned off by hand while unplugged: stays off until the next switch.
        session.turnOff()
        session.tick(now: t0 + 2, onBattery: true, followPower: true)
        #expect(!session.isOn)

        session.tick(now: t0 + 3, onBattery: true, followPower: true)
        session.turnOn(minutes: 0, now: t0 + 3)
        session.tick(now: t0 + 4, onBattery: false, followPower: true)
        #expect(!session.isOn)

        // Turned on by hand on the adapter: stands.
        session.turnOn(minutes: 0, now: t0 + 5)
        session.tick(now: t0 + 6, onBattery: false, followPower: true)
        #expect(session.isOn)
    }

    @Test func switchingTheRuleOnWhileUnpluggedTurnsItOn() {
        var session = KeepAwakeSession()
        session.tick(now: t0, onBattery: true, followPower: false)
        #expect(!session.isOn)
        session.tick(now: t0 + 1, onBattery: true, followPower: true)
        #expect(session.isOn)
    }

    @Test func theRuleOffLeavesPowerSwitchesAlone() {
        var session = KeepAwakeSession()
        session.turnOn(minutes: 0, now: t0)
        session.tick(now: t0 + 1, onBattery: true, followPower: false)
        session.tick(now: t0 + 2, onBattery: false, followPower: false)
        #expect(session.isOn)
    }
}
