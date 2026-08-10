import AppKit
import DeyleeKit
import Foundation
import ScreenCaptureKit

/// Takes screen captures while a work timer runs, if — and only if — the user asked
/// for it.
///
/// Every condition in `PRODUCT.md` §3 is enforced here rather than assumed:
///
/// - **Off by default.** `Preferences.screenCaptureEnabled` ships `false`, and while it
///   is false this service arms no timer and never touches ScreenCaptureKit. macOS is
///   not asked for screen-recording permission, so somebody who leaves the setting
///   alone is never prompted about it. Off means nothing runs, not "runs and discards".
/// - **Only while working.** A capture is taken only when the timer is `.running`. A
///   break, a pause, an ended day and a quit app all capture nothing, because the thing
///   being recorded is work, and time that is not work is not the product's business.
/// - **Revocable.** Switching the preference off stops the timer immediately; the images
///   already taken are the user's to delete from Settings, and deleting is a separate
///   act from switching off, so neither implies the other.
///
/// There is deliberately no way for this to be enabled remotely. It reads one local
/// preference and nothing else — no server flag, no policy file, no admin push.
@MainActor
final class CaptureService {
    /// What Settings needs to say about permission, which macOS only reveals by being
    /// asked. Kept separate from the preference: a user can want capture on and still
    /// not have granted the system permission, and those are different sentences.
    enum Permission: Equatable {
        case unknown
        case granted
        case denied
    }

    private(set) var permission: Permission = .unknown
    /// Reported to Settings so the screen can explain itself.
    var onPermissionChange: ((Permission) -> Void)?

    private let repo: Repository
    private let prefs: PreferencesStore
    private let now: () -> EpochMs
    /// Asked at each tick rather than pushed, so the service holds no copy of timer
    /// state that could go stale and keep capturing after a pause.
    private var isWorking: () -> Bool = { false }
    private var timer: Timer?
    private var inFlight = false

    init(
        repo: Repository,
        prefs: PreferencesStore,
        now: @escaping () -> EpochMs = { EpochMs(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.repo = repo
        self.prefs = prefs
        self.now = now
    }

    func observeTimer(_ isWorking: @escaping () -> Bool) {
        self.isWorking = isWorking
    }

    /// Start or stop to match the current preference. Safe to call repeatedly; the app
    /// calls it at launch and on every preference change.
    func reconcile() {
        let enabled = prefs.value(\.screenCaptureEnabled)
        guard enabled else {
            stop()
            return
        }
        let minutes = prefs.value(\.screenCaptureIntervalMinutes)
        start(everyMinutes: minutes)
    }

    private func start(everyMinutes minutes: Int) {
        let interval = TimeInterval(max(1, minutes) * 60)
        // Restart only when the cadence actually changed, so toggling an unrelated
        // preference does not reset the countdown to the next capture.
        if let timer, timer.timeInterval == interval, timer.isValid { return }
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureIfWorking() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One capture, if the timer is running. Also the Settings "take one now" path,
    /// which is how somebody sees what is actually being stored before trusting it.
    func captureIfWorking() async {
        guard prefs.value(\.screenCaptureEnabled), isWorking(), !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        await captureNow()
    }

    /// Capture regardless of timer state — used by Settings so the user can look at one
    /// example image immediately after switching the feature on.
    func captureNow() async {
        guard let shot = await takeScreenshot() else { return }
        let at = now()
        // Through Time.swift, like every other calendar decision in the app — a capture
        // taken at 00:00:30 belongs to the day that just started, in the user's zone.
        let day = dateKeyOf(at)
        do {
            try repo.insertCapture(
                dayDate: day,
                segmentID: try? repo.findOpenSegment()?.id,
                capturedAt: at,
                width: shot.width,
                height: shot.height,
                bytes: shot.data,
                now: at
            )
            try? sweep(at: at)
        } catch {
            // A failed capture is never worth interrupting somebody's work over. The
            // timer keeps running, the day keeps counting, and the next tick tries again.
            NSLog("[deylee] capture failed: \(error)")
        }
    }

    /// Drop captures past the retention window. Runs after each capture rather than on a
    /// schedule of its own — the only moment the set can grow is the only moment it
    /// needs trimming.
    private func sweep(at instant: EpochMs) throws {
        let days = prefs.value(\.screenCaptureRetentionDays)
        _ = try repo.sweepCaptures(olderThan: days, now: instant)
    }

    // MARK: Screen capture

    private struct Shot {
        let data: Data
        let width: Int
        let height: Int
    }

    /// The display, as a JPEG.
    ///
    /// JPEG rather than PNG, and downscaled: a lossless full-resolution Retina capture
    /// is several megabytes, and at one every ten minutes that is gigabytes a month
    /// inside a database that has to stay openable. Legibility of what was on screen is
    /// what matters here, not fidelity.
    private func takeScreenshot() async -> Shot? {
        do {
            // `excludingDesktopWindows: false` keeps the desktop, `onScreenWindowsOnly:
            // true` skips windows that are not visible anyway. Asking for shareable
            // content is also what triggers the permission prompt, which is why nothing
            // above this line runs while the feature is off.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else { return nil }
            permissionBecame(.granted)

            let configuration = SCStreamConfiguration()
            // Half-size, capped, so one image is tens of kilobytes rather than megabytes.
            let scale = min(1.0, 1440.0 / Double(display.width))
            configuration.width = Int(Double(display.width) * scale)
            configuration.height = Int(Double(display.height) * scale)
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )

            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(
                using: .jpeg, properties: [.compressionFactor: 0.5]
            ) else { return nil }
            return Shot(data: data, width: image.width, height: image.height)
        } catch {
            // The permission dialog is answered asynchronously and refusal surfaces as a
            // thrown error here. Recorded so Settings can say "macOS has not granted
            // this" rather than leaving a switch that is on and does nothing.
            permissionBecame(.denied)
            NSLog("[deylee] screen capture unavailable: \(error)")
            return nil
        }
    }

    private func permissionBecame(_ next: Permission) {
        guard permission != next else { return }
        permission = next
        onPermissionChange?(next)
    }

    /// Open the pane where macOS keeps the switch, since the app cannot grant itself
    /// permission and a user who denied it once is never asked again.
    static func openSystemPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
