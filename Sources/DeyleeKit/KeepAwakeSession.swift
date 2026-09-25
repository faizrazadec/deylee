/// Whether the Mac should be held awake, and until when.
///
/// The rules only; the app turns the answer into a power assertion. Advanced by
/// ``tick(now:onBattery:followPower:)`` on the status item's one-second refresh, so a
/// timed session ends on the first tick past its end even if the Mac slept through it.
public struct KeepAwakeSession: Equatable, Sendable {
    /// The lengths the menu offers, in minutes. `0` is "until turned off".
    public static let presetMinutes = [5, 15, 60, 120, 300, 0]

    public private(set) var isOn = false
    /// When a timed session ends. `nil` while off, or on until turned off.
    public private(set) var endsAt: EpochMs?
    /// The power source at the last tick, recorded only while the battery rule is on,
    /// so switching the rule on while unplugged counts as a change.
    private var lastOnBattery: Bool?

    public init() {}

    /// Starts a session, replacing any running one. `minutes <= 0` runs until turned off.
    public mutating func turnOn(minutes: Int, now: EpochMs) {
        isOn = true
        endsAt = minutes > 0 ? now + Int64(minutes) * 60_000 : nil
    }

    public mutating func turnOff() {
        isOn = false
        endsAt = nil
    }

    /// Ends a timed session that is due, and applies the battery rule: on when the Mac
    /// switches to battery, off when it switches back to the adapter. Only a switch
    /// acts, so a session the user changes by hand stands until the next one.
    public mutating func tick(now: EpochMs, onBattery: Bool, followPower: Bool) {
        if let endsAt, now >= endsAt { turnOff() }

        guard followPower else {
            lastOnBattery = nil
            return
        }
        defer { lastOnBattery = onBattery }
        guard onBattery != lastOnBattery else { return }
        if onBattery {
            turnOn(minutes: 0, now: now)
        } else if lastOnBattery != nil {
            turnOff()
        }
    }
}
