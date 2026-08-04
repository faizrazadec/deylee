import AppKit
import DeyleeKit

/// Boots the app and owns everything with a lifetime.
///
/// Startup order matters and mirrors the Electron build: open the store and migrate
/// before anything can write, detect a leftover open segment **before** the engine
/// exists (so no transition can close it first), then start the services.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var db: Database?
    private var repo: Repository?
    private var engine: TimerEngine?
    private var prefs: PreferencesStore?
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var miniWindow: MiniWindowController?
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var stopWatchingPreferences: PreferencesUnsubscribe?
    private var idleMonitor: IdleMonitor?
    private var powerMonitor: PowerMonitor?
    private var reminderService: ReminderService?
    private var rolloverTimer: Timer?
    private var heartbeatTimer: Timer?
    private var pendingRecovery: PendingRecovery?
    /// Whether the last away event actually closed a work segment. Only then is there a
    /// gap the user needs to attribute on the way back.
    private var autoPausedByPower = false

    /// Splits a running segment at local midnight. A timer aimed at midnight would
    /// sleep through it, so the check runs every second instead; the no-work path is
    /// two indexed reads.
    private static let rolloverIntervalMs = 1_000
    /// Records that the app was alive, so a crash can be recovered to the last known
    /// good instant rather than the segment's start.
    private static let heartbeatIntervalMs = 30_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try boot()
        } catch let error as SchemaTooNewError {
            refuseToStart(
                title: "This data was written by a newer Deylee",
                message: """
                    Your database is at schema version \(error.storedVersion), but this build \
                    only understands version \(error.supportedVersion).

                    Nothing has been changed and nothing has been lost. Update Deylee to the \
                    latest release and your data will open again exactly as you left it.
                    """
            )
        } catch {
            refuseToStart(title: "Deylee could not start", message: "\(error)")
        }
    }

    private func boot() throws {
        let db = try DataStore.open()
        let repo = Repository(db: db)
        let prefs = DefaultPreferencesStore(
            backend: UserDefaultsPreferencesBackend(),
            defaults: .defaults
        )

        // Read before the engine exists: once it does, a transition could close the
        // leftover segment and the evidence of the crash would be gone.
        if let orphan = try repo.findOpenSegment() {
            let heartbeat = try repo.appState(Repository.appStateHeartbeat).flatMap(EpochMs.init)
            let pending = buildPendingRecovery(orphan, lastHeartbeatAt: heartbeat)
            if isRecoveryWorthPrompting(pending) {
                pendingRecovery = pending
            } else {
                // Too short to be worth asking about; a phantom row is worse than
                // silently dropping a sub-second segment.
                try repo.deleteSegment(orphan.id)
            }
        }

        let engine = TimerEngine(repo: repo, prefs: prefs)
        let model = AppModel(engine: engine, repo: repo, initial: try engine.snapshot())

        self.db = db
        self.repo = repo
        self.prefs = prefs
        self.engine = engine
        self.model = model

        let settingsModel = SettingsModel(store: prefs)
        let settingsWindow = SettingsWindowController(model: settingsModel)
        self.settingsModel = settingsModel
        self.settingsWindow = settingsWindow

        model.openHistoryWindow = { HistoryWindow.open(repo: repo, engine: engine, prefs: prefs) }
        model.openSettingsWindow = { settingsWindow.show() }

        // Applied before any window exists: the change listener alone would leave the
        // first launch on the system appearance regardless of a stored light/dark choice.
        applyTheme(prefs.value(\.theme))
        stopWatchingPreferences = prefs.onChange { [weak self] next in
            Task { @MainActor in self?.preferencesChanged(next, engine: engine) }
        }

        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem

        // The controller watches `showMiniWindow` itself, so toggling the preference
        // creates or destroys the window live with no further wiring.
        miniWindow = MiniWindowController(
            model: model,
            prefs: prefs,
            openPanel: { [weak statusItem] in statusItem?.showPanel() }
        )

        engine.onSnapshot { [weak self] (snapshot: TimerSnapshot) in
            self?.model?.apply(snapshot)
            self?.statusItem?.refresh()
        }

        startIdleMonitor(engine: engine, repo: repo, prefs: prefs)
        startPowerMonitor(engine: engine, prefs: prefs)
        startRollover(engine: engine)
        startHeartbeat(repo: repo, engine: engine)

        let reminder = ReminderService(
            prefs: prefs,
            isRunning: { [weak self] in self?.model?.snapshot.state == .running },
            post: { [weak self] notice in self?.model?.post(notice) }
        )
        reminder.start()
        reminderService = reminder

        reconcileLoginItem(prefs: prefs)
        model.apply(try engine.snapshot())

        // Last, so the queue is handed a fully booted app: the prompt is the first
        // thing the user sees, and answering it writes through the engine immediately.
        if let pending = pendingRecovery {
            pendingRecovery = nil
            model.prompts.enqueue(recovery: pending)
            statusItem.showPanel()
        }
    }

    // MARK: - Services

    private func startIdleMonitor(engine: TimerEngine, repo: Repository, prefs: PreferencesStore) {
        let monitor = IdleMonitor(
            isRunning: { [weak self] in self?.model?.snapshot.state == .running },
            settings: {
                let current = prefs.getAll()
                return (current.idleDetectionEnabled, current.idleThresholdMinutes)
            },
            onIdleDetected: { [weak self] idleStartedAt, idleMs in
                self?.handleIdle(idleStartedAt: idleStartedAt, idleMs: idleMs)
            }
        )
        monitor.start()
        idleMonitor = monitor
    }

    private func handleIdle(idleStartedAt: EpochMs, idleMs: Int64) {
        guard let repo, let model, let statusItem,
              let open = (try? repo.findOpenSegment()) ?? nil, open.type == .work
        else { return }
        // The segment is captured in the prompt, so an answer given ten minutes later
        // still trims the stretch the question was about.
        model.prompts.enqueue(
            idle: IdlePrompt(
                id: UUID(), segmentId: open.id,
                idleStartedAt: idleStartedAt, idleMs: idleMs
            )
        )
        // A prompt the user cannot see is a prompt they cannot answer, so the panel
        // opens with it rather than relying on a notification they may have dismissed.
        statusItem.showPanel()
    }

    private func startPowerMonitor(engine: TimerEngine, prefs: PreferencesStore) {
        let monitor = PowerMonitor(
            autoPauseOnSleep: { prefs.value(\.autoPauseOnSleep) },
            autoPauseOnLock: { prefs.value(\.autoPauseOnLock) },
            onAway: { [weak self] at, _ in
                self?.handleAway(engine: engine, at: at)
            },
            onBack: { [weak self] awayAt, backAt, reason in
                self?.handleWake(awayAt: awayAt, backAt: backAt, reason: reason)
            }
        )
        monitor.start()
        powerMonitor = monitor
    }

    private func handleAway(engine: TimerEngine, at: EpochMs) {
        guard let model, let open = model.snapshot.openSegment, open.type == .work else {
            autoPausedByPower = false
            return
        }
        try? engine.suspend(at: at)
        // `suspend` refuses to store an empty segment, so whether the work segment
        // really closed is the only honest signal that there is a gap to ask about.
        autoPausedByPower = model.snapshot.openSegment == nil
    }

    private func handleWake(awayAt: EpochMs, backAt: EpochMs, reason: WakeReason) {
        // Without a matching auto-pause there is no gap to attribute.
        guard let model, let statusItem, autoPausedByPower else { return }
        autoPausedByPower = false
        model.prompts.enqueue(
            wake: WakePrompt(
                id: UUID(), reason: reason,
                gapStartedAt: awayAt, gapEndedAt: backAt,
                gapMs: max(0, backAt - awayAt)
            )
        )
        statusItem.showPanel()
    }

    private func startRollover(engine: TimerEngine) {
        let interval = Double(Self.rolloverIntervalMs) / 1_000
        rolloverTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Never fatal: a failed split is retried a second later, and throwing
                // out of a timer would take the app down over a transient lock.
                _ = try? engine.rollOverMidnight()
            }
        }
    }

    private func startHeartbeat(repo: Repository, engine: TimerEngine) {
        let interval = Double(Self.heartbeatIntervalMs) / 1_000
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.model?.snapshot.openSegment != nil else { return }
                self?.writeHeartbeat()
            }
        }
    }

    /// Losing heartbeat precision is cheaper than crashing, so a failed write is
    /// logged and forgotten.
    private func writeHeartbeat() {
        try? repo?.setAppState(Repository.appStateHeartbeat, String(epochNow()))
    }

    /// Everything a preference change has to move, from one signal.
    private func preferencesChanged(_ next: Preferences, engine: TimerEngine) {
        applyTheme(next.theme)
        // Only the day in progress is re-stamped; past days keep the goal they were
        // actually run against.
        _ = try? engine.syncTodayTarget()
        // The mini controller watches the preference itself, so nothing to do for it
        // here. The login item only ever follows the OS — never re-registered behind
        // the user's back, because they may have removed it in System Settings.
        if let prefs { reconcileLoginItem(prefs: prefs) }
    }

    private func applyTheme(_ theme: Theme) {
        NSApp.appearance = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The OS is the source of truth: the user can remove the login item in System
    /// Settings without Deylee hearing about it, so the preference follows the system
    /// rather than asserting itself over it.
    private func reconcileLoginItem(prefs: PreferencesStore) {
        let actual = LoginItem.isEnabled
        if prefs.value(\.launchAtLogin) != actual {
            prefs.set(\.launchAtLogin, to: actual)
        }
    }

    // MARK: - Lifecycle

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The final heartbeat goes first: everything after it can only lose time that
        // this stamp has already accounted for.
        writeHeartbeat()
        // A quit inside the 300 ms move debounce would otherwise forget where the
        // user left the widget.
        miniWindow?.flushPendingPosition()
        rolloverTimer?.invalidate()
        heartbeatTimer?.invalidate()
        idleMonitor?.stop()
        powerMonitor?.stop()
        reminderService?.stop()
        stopWatchingPreferences?()
        settingsModel?.stopObserving()
        return .terminateNow
    }

    /// Relaunching from the Dock or Finder surfaces the panel rather than doing
    /// nothing, which is what an accessory app with no windows would otherwise do.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem?.showPanel()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func refuseToStart(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
