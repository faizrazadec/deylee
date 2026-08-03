import AppKit
import DaylyKit

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
    private var idleMonitor: IdleMonitor?
    private var powerMonitor: PowerMonitor?
    private var rolloverTimer: Timer?
    private var heartbeatTimer: Timer?
    private var pendingRecovery: PendingRecovery?

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
                title: "This data was written by a newer Dayly",
                message: """
                    Your database is at schema version \(error.storedVersion), but this build \
                    only understands version \(error.supportedVersion).

                    Nothing has been changed and nothing has been lost. Update Dayly to the \
                    latest release and your data will open again exactly as you left it.
                    """
            )
        } catch {
            refuseToStart(title: "Dayly could not start", message: "\(error)")
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

        model.openHistoryWindow = { NSLog("[dayly] history window not built yet") }
        model.openSettingsWindow = { NSLog("[dayly] settings window not built yet") }

        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem

        engine.onSnapshot { [weak self] (snapshot: TimerSnapshot) in
            self?.model?.apply(snapshot)
            self?.statusItem?.refresh()
        }

        startIdleMonitor(engine: engine, repo: repo, prefs: prefs)
        startPowerMonitor(engine: engine, prefs: prefs)
        startRollover(engine: engine)
        startHeartbeat(repo: repo, engine: engine)

        reconcileLoginItem(prefs: prefs)
        model.apply(try engine.snapshot())
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
        guard let repo, let statusItem,
              let open = (try? repo.findOpenSegment()) ?? nil, open.type == .work
        else { return }
        // A prompt the user cannot see is a prompt they cannot answer, so the panel
        // opens with it rather than relying on a notification they may have dismissed.
        statusItem.showPanel()
        NSLog("[dayly] idle for \(formatCompact(idleMs)) from \(formatClock(idleStartedAt))")
    }

    private func startPowerMonitor(engine: TimerEngine, prefs: PreferencesStore) {
        let monitor = PowerMonitor(
            autoPauseOnSleep: { prefs.value(\.autoPauseOnSleep) },
            autoPauseOnLock: { prefs.value(\.autoPauseOnLock) },
            onAway: { at, _ in
                try? engine.suspend(at: at)
            },
            onBack: { [weak self] awayAt, backAt, reason in
                self?.handleWake(awayAt: awayAt, backAt: backAt, reason: reason)
            }
        )
        monitor.start()
        powerMonitor = monitor
    }

    private func handleWake(awayAt: EpochMs, backAt: EpochMs, reason: WakeReason) {
        statusItem?.showPanel()
        NSLog("[dayly] back after \(formatCompact(backAt - awayAt)) (\(reason.rawValue))")
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

    /// The OS is the source of truth: the user can remove the login item in System
    /// Settings without Dayly hearing about it, so the preference follows the system
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
        rolloverTimer?.invalidate()
        heartbeatTimer?.invalidate()
        idleMonitor?.stop()
        powerMonitor?.stop()
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
