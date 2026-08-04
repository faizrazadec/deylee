import AppKit
import Observation
import DeyleeKit

/// The one piece of state every surface observes.
///
/// It holds the latest snapshot and today's segments; it never computes elapsed time
/// itself. Views recompute that from timestamps on their own tick, which is what
/// keeps the display correct across sleep, a clock change and midnight.
///
/// Actions are fire-and-forget: nothing is mutated locally, the view waits for the
/// engine's next snapshot. A local optimistic update would be a second source of
/// truth, and the whole design is built on there being exactly one.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: TimerSnapshot
    private(set) var todaySegments: [Segment] = []
    /// False until the first snapshot lands, so buttons stay inert rather than
    /// offering an action against a state we have not read yet.
    private(set) var hasLoaded = false
    private(set) var notices: [Notice] = []

    var pendingEndDayConfirm = false

    /// Recovery, idle and wake prompts. Held here rather than in the panel window so a
    /// question raised while the panel is closed is still waiting when it opens.
    let prompts: PromptQueue

    @ObservationIgnored private let engine: TimerEngine
    @ObservationIgnored private let repo: Repository
    @ObservationIgnored var openHistoryWindow: () -> Void = {}
    @ObservationIgnored var openSettingsWindow: () -> Void = {}

    init(engine: TimerEngine, repo: Repository, initial: TimerSnapshot) {
        self.engine = engine
        self.repo = repo
        self.snapshot = initial
        self.prompts = PromptQueue(engine: engine, repo: repo)
        // A queued question outranks a confirmation the user opened themselves.
        prompts.onPromptShown = { [weak self] in self?.pendingEndDayConfirm = false }
    }

    func apply(_ snapshot: TimerSnapshot) {
        self.snapshot = snapshot
        hasLoaded = true
        refreshToday()
    }

    func refreshToday() {
        // A failed local read is not worth an error surface at 320 pt wide; the list
        // simply keeps whatever it last showed and the next snapshot retries.
        todaySegments = (try? repo.dayDetail(snapshot.date, now: epochNow()))??.segments ?? []
    }

    // MARK: - Actions

    func primaryAction() {
        switch snapshot.state {
        case .running: run { try engine.pause() }
        case .paused: run { try engine.resume() }
        case .idle, .ended: run { try engine.start() }
        }
    }

    func confirmEndDay() {
        pendingEndDayConfirm = true
    }

    func endDay() {
        pendingEndDayConfirm = false
        run { try engine.endDay() }
    }

    func openHistory() { openHistoryWindow() }
    func openSettings() { openSettingsWindow() }

    func post(_ notice: Notice) {
        notices.append(notice)
    }

    func dismiss(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
    }

    /// Transitions are no-ops when they cannot legally happen, so a failure here is a
    /// storage problem, not a user error — log it and leave the last good state on
    /// screen rather than blanking the panel.
    private func run(_ body: () throws -> TimerSnapshot) {
        do {
            apply(try body())
        } catch {
            NSLog("[deylee] timer transition failed: \(error)")
        }
    }
}
