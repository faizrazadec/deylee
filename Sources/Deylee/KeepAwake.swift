import IOKit.pwr_mgt

/// Keeps the Mac and its display awake while switched on — what `caffeinate -di` or
/// KeepingYouAwake do, folded in so one menu-bar app covers both.
///
/// A power assertion rather than a spawned `caffeinate`: it is released by the kernel
/// if the process dies, so a crash never leaves the Mac unable to sleep. It does not
/// touch the HID idle clock, so idle detection still sees an absent user.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID?

    var isOn: Bool { assertion != nil }

    func toggle() {
        if let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
            return
        }
        var id = IOPMAssertionID(0)
        // Display-sleep prevention implies system-sleep prevention while the lid is open.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Deylee: Keep Awake" as CFString,
            &id
        )
        if result == kIOReturnSuccess { assertion = id }
    }
}
