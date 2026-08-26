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

    /// Whether an account is still needed. False on a build with no API, where
    /// nothing is ever gated and the app is the local tracker it always was.
    @ObservationIgnored var needsSignIn: () -> Bool = { false }

    /// Raises sign-in and runs the closure afterwards, but only if it succeeded.
    ///
    /// Supplied by the app, which owns the windows: signing in replaces whatever
    /// raised it and that window comes back when it is done.
    @ObservationIgnored var presentSignIn: (@escaping () -> Void) -> Void = { _ in }

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
        case .idle, .ended:
            // Starting a day is the moment an account starts to matter, because it
            // is the first thing worth syncing. Asking here rather than at launch
            // means somebody can open the app, look at it, and decide — and the
            // one press they made still does what they pressed it for: sign-in
            // resolves and the timer starts without a second click.
            guard needsSignIn() else {
                run { try engine.start() }
                return
            }
            presentSignIn { [weak self] in
                self?.run { try self!.engine.start() }
            }
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

    /// Where feedback goes. One line, because it is the only thing about this feature
    /// worth configuring.
    private static let feedbackAddress = "faiz.raza.dec@gmail.com"

    /// Opens a mail draft. It lives on the panel rather than in Settings because a bug
    /// is reported at the moment it is noticed, and nobody goes hunting through
    /// preferences at that moment.
    ///
    /// The version and OS go in as plain readable text the person can delete before
    /// sending. Nothing is attached and no request is made: the moment something travels
    /// that they cannot see, this has become the thing it was avoiding.
    func sendFeedback() {
        let body = "\n\n---\nDeylee \(DeyleeKit.version) · "
            + ProcessInfo.processInfo.operatingSystemVersionString
        guard var components = URLComponents(
            string: "mailto:\(AppModel.feedbackAddress)"
        ) else { return }
        components.queryItems = [
            .init(name: "subject", value: "Deylee feedback"),
            .init(name: "body", value: body),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

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
