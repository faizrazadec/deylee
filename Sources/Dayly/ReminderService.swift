import Foundation
import DaylyKit

/// The end-of-day nudge: one notice, once a day, while the timer is still running.
///
/// A repeating tick rather than a timer aimed at the due time — see `ReminderSchedule`,
/// which holds the rule this only has to drive.
@MainActor
final class ReminderService {
    /// Checked every minute, which is the resolution the setting itself has.
    static let tickIntervalMs = 60_000

    static let noticeTitle = "Still tracking"
    static let noticeBody = "Your timer is still running. End the day when you are done."

    private var timer: Timer?
    private var schedule = ReminderSchedule()

    private let prefs: PreferencesStore
    private let isRunning: () -> Bool
    private let post: (Notice) -> Void

    init(
        prefs: PreferencesStore,
        isRunning: @escaping () -> Bool,
        post: @escaping (Notice) -> Void
    ) {
        self.prefs = prefs
        self.isRunning = isRunning
        self.post = post
    }

    func start() {
        stop()
        let interval = Double(Self.tickIntervalMs) / 1_000
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let current = prefs.getAll()
        guard schedule.shouldFire(
            now: epochNow(),
            enabled: current.reminderEnabled,
            isRunning: isRunning(),
            reminderHour: current.reminderHour,
            reminderMinute: current.reminderMinute
        ) else { return }

        post(Notice(level: .info, title: Self.noticeTitle, body: Self.noticeBody))
    }
}
