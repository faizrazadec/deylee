import AppKit
import SwiftUI
import DeyleeKit

/// Owns the `NSStatusItem`, its menu, and the panel it toggles.
///
/// The native replacement for the Electron tray plus the `mac-status-item` addon:
/// AppKit gives the highlight, the click routing and the menu placement for free,
/// so the only real work here is keeping the title and tooltip current.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// How often the title is re-derived. Faster than the eye needs, slow enough to
    /// be free; the menu-bar total ticks in minutes but the tooltip shows seconds.
    private static let refreshIntervalMs = 1_000

    private let statusItem: NSStatusItem
    private let model: AppModel
    private let panel: PanelWindow
    /// Held detached and attached only for a secondary click — a permanently attached
    /// menu would open on a left click too, and a left click must show the panel.
    private let menu = NSMenu()
    /// The state the menu was last built for. Rebuilding on every snapshot would
    /// close the menu under the user's cursor.
    private var menuBuiltFor: TimerState?
    private var refreshTimer: Timer?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = PanelWindow { PanelView(model: model) }
        super.init()

        if let button = statusItem.button {
            button.image = StatusItemGlyph.make()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.autoenablesItems = false
        menu.delegate = self

        panel.onVisibilityChange = { [weak self] visible in
            self?.setHighlighted(visible)
        }

        rebuildMenu(for: model.snapshot.state)
        refresh()
        startRefreshTimer()
    }

    deinit {
        MainActor.assumeIsolated { refreshTimer?.invalidate() }
    }

    /// Holds the button lit for exactly as long as the panel is on screen.
    ///
    /// Deferred by a turn of the run loop, which is the whole trick. The visibility
    /// change arrives from inside the button's action, and that action runs *during*
    /// AppKit's mouse tracking; tracking restores the button's own highlight state when
    /// it finishes, so anything set synchronously here is overwritten a moment later
    /// and the user sees a flash rather than a held highlight.
    private func setHighlighted(_ highlighted: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.isHighlighted = highlighted
        }
    }

    // MARK: - Clicks

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondary {
            showMenu()
        } else {
            panel.toggle(below: statusItem.button?.window?.frame)
        }
    }

    private func showMenu() {
        rebuildMenu(for: model.snapshot.state)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detached on the next run-loop turn: clearing it inside the close callback
        // would pull the menu out from under AppKit while it is still dismissing.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - Title and tooltip

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = Double(Self.refreshIntervalMs) / 1_000
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Called on the tick and immediately on every snapshot.
    func refresh() {
        guard let button = statusItem.button else { return }
        let live = liveTotals(model.snapshot, now: epochNow())
        let state = model.snapshot.state

        // Worked time only, never the break total, and only while there is something
        // running to report. Paused deliberately shows the frozen total rather than
        // hiding it, so stepping away does not look like lost time.
        let title = (state == .running || state == .paused) ? formatHM(live.workedMs) : ""
        button.title = title
        // An empty title still reserves the icon-text gap unless the position changes.
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = tooltip(state: state, live: live)

        if menuBuiltFor != state { rebuildMenu(for: state) }
    }

    private func tooltip(state: TimerState, live: LiveTotals) -> String {
        let totals = "\(formatHM(live.workedMs)) worked · \(formatHM(live.breakMs)) break"
        switch state {
        case .running: return "Deylee — \(totals)"
        case .paused: return "Deylee — paused · \(totals)"
        case .ended: return "Deylee — day ended · \(totals)"
        case .idle: return live.workedMs > 0 ? "Deylee — stopped · \(totals)" : "Deylee — not tracking"
        }
    }

    // MARK: - Menu

    private func rebuildMenu(for state: TimerState) {
        menuBuiltFor = state
        menu.removeAllItems()

        let primaryTitle: String
        switch state {
        case .running: primaryTitle = "Pause"
        case .paused: primaryTitle = "Resume"
        case .idle, .ended: primaryTitle = "Start"
        }
        add(primaryTitle, #selector(primaryAction), enabled: true)

        add("End Day", #selector(endDay), enabled: state == .running || state == .paused)
        menu.addItem(.separator())
        add("Open Deylee", #selector(openPanel), enabled: true)
        add("History", #selector(openHistory), enabled: true)
        add("Settings", #selector(openSettings), enabled: true)
        menu.addItem(.separator())
        add("Quit", #selector(quit), enabled: true)
    }

    private func add(_ title: String, _ action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // The action is resolved from the live state at click time, not the state the
    // menu was built for — the two can differ if the timer moved while it was open.
    @objc private func primaryAction() { model.primaryAction(); refresh() }
    @objc private func endDay() { model.endDay(); refresh() }
    @objc private func openPanel() { panel.show(below: statusItem.button?.window?.frame) }
    @objc private func openHistory() { model.openHistory() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func showPanel() {
        panel.show(below: statusItem.button?.window?.frame)
    }

    /// Steps the panel aside without dismissing anything it was asking about.
    ///
    /// Used when sign-in has to take its place: the panel is a popover and would
    /// resign key anyway, but relying on that would mean the panel's return
    /// depended on a side effect rather than on being told.
    func hidePanel() {
        panel.hide()
    }
}
