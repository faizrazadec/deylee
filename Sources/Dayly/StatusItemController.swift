import AppKit
import SwiftUI
import DaylyKit

/// Owns the `NSStatusItem`, its menu, and the panel it toggles.
///
/// The native replacement for the Electron tray plus the `mac-status-item` addon.
/// AppKit gives the click routing and the menu placement for free; the highlight it
/// does not, because its own is tied to mouse tracking and drops out before the panel
/// is up, so the fill is drawn here instead.
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
    /// Whether the fill should currently be drawn. Kept so the once-a-second refresh
    /// can re-resolve it, which is what keeps the colour correct if the system flips
    /// between light and dark while the panel is open.
    private var highlightOn = false
    /// The fill, kept as its own sublayer so it can be inset and capsule-shaped
    /// independently of the button, whose own bounds span the full bar height.
    private var highlightLayer: CALayer?

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
            // AppKit's own press highlight is turned off so it cannot fight ours.
            // Its highlight comes on at mouse-down and goes off the instant tracking
            // ends, which is before the panel is up — the eye reads that off-then-on
            // as a blink. With it disabled the fill below is the only one drawn, and
            // it simply stays on from the click until the panel closes.
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.wantsLayer = true
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

    /// Holds the button lit for exactly as long as the panel or the menu is up.
    ///
    /// Drawn rather than delegated to `isHighlighted`: AppKit resets that when mouse
    /// tracking ends, so the fill would drop out between the click and the panel
    /// appearing and read as a blink. A layer colour is not tracking state, so nothing
    /// takes it back — it is on from the click until the panel closes.
    private func setHighlighted(_ highlighted: Bool) {
        highlightOn = highlighted
        applyHighlight()
    }

    private func applyHighlight() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let hostLayer = button.layer else { return }

        let fill = highlightLayer ?? {
            let layer = CALayer()
            // Behind the glyph, never over it.
            hostLayer.insertSublayer(layer, at: 0)
            highlightLayer = layer
            return layer
        }()

        // No implicit animation: the fill has to land on the same frame as the click,
        // and a resize has to follow the title without sliding after it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Re-framed every time because the button grows and shrinks with the H:MM
        // title as the minutes tick over.
        // The button's own bounds are already inset from the bar — 22 pt inside a
        // 33 pt menu bar on this display — which is exactly the inset the system's
        // pill has. Insetting again only made it look squat. A radius of half the
        // height is what turns it from a rounded square into the capsule the menu bar
        // draws around an active extra.
        fill.frame = button.bounds
        fill.cornerRadius = button.bounds.height / 2
        // A dynamic NSColor snapshots the *current* appearance when it becomes a
        // CGColor, which is not necessarily the menu bar's — resolving against the
        // button's own appearance is what keeps it right in both themes.
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.backgroundColor = highlightOn ? Self.highlightColor.cgColor : nil
        }
        CATransaction.commit()
    }

    /// The menu bar's highlight is a translucent overlay rather than an accent tint, so
    /// it reads the same over a light desktop, a dark one and a wallpaper.
    private static var highlightColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(0.20)
                : NSColor.black.withAlphaComponent(0.13)
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

    func menuWillOpen(_ menu: NSMenu) {
        // The right-click menu gets the same held fill as the panel; AppKit would
        // normally light the button itself, but its highlight is disabled here.
        setHighlighted(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Unless the panel is up behind it, in which case the fill stays.
        setHighlighted(panel.isVisible)
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
        // Re-resolved every tick so a light/dark switch cannot leave the fill in the
        // other theme's colour.
        if highlightOn { applyHighlight() }
    }

    private func tooltip(state: TimerState, live: LiveTotals) -> String {
        let totals = "\(formatHM(live.workedMs)) worked · \(formatHM(live.breakMs)) break"
        switch state {
        case .running: return "Dayly — \(totals)"
        case .paused: return "Dayly — paused · \(totals)"
        case .ended: return "Dayly — day ended · \(totals)"
        case .idle: return live.workedMs > 0 ? "Dayly — stopped · \(totals)" : "Dayly — not tracking"
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
        add("Open Dayly", #selector(openPanel), enabled: true)
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
}
