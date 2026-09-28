import Foundation
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
    private let lidGuard = LidSleepGuard()
    /// The password was refused for this session, so it is not asked for again on every
    /// tick. Cleared when the session ends, so the next one asks afresh.
    private var lidDeclined = false

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
        applyLidGuard()
        // Awake with the lid closed means working in the background, not lighting a screen.
        let allowDisplaySleep = prefs.value(\.keepAwakeAllowDisplaySleep)
            || prefs.value(\.keepAwakeLidClosed)
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

    private func applyLidGuard() {
        if !session.isOn { lidDeclined = false }
        let wanted = session.isOn && prefs.value(\.keepAwakeLidClosed) && !lidDeclined
        if wanted, !lidGuard.isEngaged {
            lidGuard.engage { [weak self] engaged in
                if !engaged { self?.lidDeclined = true }
            }
        } else if !wanted, lidGuard.isEngaged {
            lidGuard.release()
        }
    }

    private static func onBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        return source == kIOPMBatteryPowerKey
    }
}

/// Keeps the Mac awake with the lid closed, which no power assertion can do: closing the
/// lid sleeps the Mac whatever assertions are held. `pmset disablesleep` can, and it
/// needs root, so each session asks for the administrator's password once.
///
/// The danger is a Mac that cannot sleep, shut in a bag. So the privileged command also
/// starts a root watchdog that puts sleep back as soon as this process exits (a crash
/// included) or the flag file is gone. Releasing is deleting that file, which needs no
/// password, so a session that ends while the lid is shut still lets the Mac sleep.
@MainActor
final class LidSleepGuard {
    private static let flag = FileManager.default.temporaryDirectory
        .appending(path: "deylee-lid-awake")

    private(set) var isEngaged = false

    init() {
        // A flag left by a run that crashed. Its watchdog has already put sleep back,
        // because that process is gone; this only stops a reused pid keeping it alive.
        release()
    }

    /// Asks for the password and disables sleep. `done` says whether it took.
    func engage(done: @escaping @MainActor (Bool) -> Void) {
        isEngaged = true
        FileManager.default.createFile(atPath: Self.flag.path, contents: nil)
        let script = Self.appleScript(
            pid: ProcessInfo.processInfo.processIdentifier, flag: Self.flag.path
        )
        NSLog("[deylee] lid closed: asking for the administrator password")
        Task.detached {
            let (engaged, detail) = Self.runAppleScript(script)
            NSLog("[deylee] lid closed: %@", engaged ? "sleep disabled" : "not disabled: \(detail)")
            await MainActor.run {
                if !engaged { self.release() }
                done(engaged)
            }
        }
    }

    func release() {
        isEngaged = false
        try? FileManager.default.removeItem(at: Self.flag)
    }

    /// The watchdog takes the pid and the flag as arguments rather than pasted into its
    /// own quotes, so the only thing quoted into the command is the flag's path.
    // ponytail: polls every 2 s as root; a launchd job watching the file if that ever shows.
    nonisolated static func shellCommand(pid: Int32, flag: String) -> String {
        let quoted = "'" + flag.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let watch = "while /bin/kill -0 \"$1\" 2>/dev/null && [ -e \"$2\" ]; do /bin/sleep 2; done; "
            + "/usr/bin/pmset -a disablesleep 0"
        // `|| exit 1` rather than `&&`: `a && b &` would background both, and a pmset that
        // failed would still report success.
        return "/usr/bin/pmset -a disablesleep 1 || exit 1; /usr/bin/nohup /bin/sh -c '\(watch)' "
            + "deylee-lid-watch \(pid) \(quoted) >/dev/null 2>&1 &"
    }

    nonisolated static func appleScript(pid: Int32, flag: String) -> String {
        let command = shellCommand(pid: pid, flag: flag)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(command)\" with prompt "
            + "\"Deylee wants to keep your Mac awake with the lid closed.\" "
            + "with administrator privileges"
    }

    /// Off the main thread: the password dialog stays up for as long as the person
    /// takes, and the menu bar must keep working meanwhile. Cancelling exits non-zero,
    /// and what osascript said is returned so a refusal can be told from a cancel.
    nonisolated private static func runAppleScript(_ script: String) -> (Bool, String) {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return (false, "\(error)")
        }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus == 0, said.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
