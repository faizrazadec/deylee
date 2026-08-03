import AppKit
import SwiftUI
import DaylyKit

/// Where the mini window sits, per display.
///
/// Deliberately not a ported preference. The Electron build stored top-left-origin
/// points keyed by Electron's own display id, and `DaylyKit` ignores that key rather
/// than importing coordinates that mean something else here — these are AppKit
/// bottom-left origins keyed by `CGDirectDisplayID`. Its own defaults key keeps the
/// two from ever being read as each other.
///
/// The file behind `UserDefaults` is user-editable and survives downgrades, so a
/// stored point is validated on the way out: a window placed at NaN is unreachable.
struct MiniPositionStore {
    static let defaultsKey = "dayly.miniWindowPositionsByDisplay"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func position(for displayId: CGDirectDisplayID) -> CGPoint? {
        guard let entry = all()[String(displayId)],
              let x = entry["x"], let y = entry["y"],
              x.isFinite, y.isFinite
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Merges, never replaces: every other display keeps the spot the user chose for
    /// it, including displays that are not attached right now.
    func setPosition(_ point: CGPoint, for displayId: CGDirectDisplayID) {
        guard point.x.isFinite, point.y.isFinite else { return }
        var stored = all()
        stored[String(displayId)] = ["x": point.x, "y": point.y]
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    private func all() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Double]] ?? [:]
    }
}

/// The floating mini window, and the preference that decides whether it exists.
///
/// The window is created and destroyed rather than shown and hidden: its existence is
/// bound entirely to `showMiniWindow`, and a hidden window that still holds a screen
/// position would drift out of step with the preference that is supposed to own it.
@MainActor
final class MiniWindowController {
    /// A drag emits a stream of move events; only where the window comes to rest is
    /// worth a write.
    private static let moveDebounceMs = 300

    private let model: AppModel
    private let prefs: PreferencesStore
    private let positions: MiniPositionStore
    private let openPanel: () -> Void

    private var window: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var pendingSave: DispatchWorkItem?
    private var prefsSubscription: PreferencesUnsubscribe?

    var isOpen: Bool { window != nil }

    init(
        model: AppModel,
        prefs: PreferencesStore,
        positions: MiniPositionStore = MiniPositionStore(),
        openPanel: @escaping () -> Void
    ) {
        self.model = model
        self.prefs = prefs
        self.positions = positions
        self.openPanel = openPanel

        sync(show: prefs.value(\.showMiniWindow))
        prefsSubscription = prefs.onChange { [weak self] preferences in
            let show = preferences.showMiniWindow
            // A preference write can land from anywhere; the window may only be
            // touched on the main actor.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sync(show: show) }
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            prefsSubscription?()
            // No flush: a controller being torn down has no window left to read a
            // position from, and `destroy` has already written one.
            pendingSave?.cancel()
        }
    }

    /// Creates or destroys the window to match the preference.
    func sync(show: Bool) {
        if show {
            if window == nil { create() }
        } else {
            destroy()
        }
    }

    /// Writes a debounced position immediately, for a quit that will not give the
    /// window a chance to report where it ended up.
    func flushPendingPosition() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        rememberPosition()
    }

    // MARK: - Lifecycle

    private func create() {
        let panel = NSPanel(
            contentRect: NSRect(origin: resolveOrigin(), size: Layout.miniSize),
            // Non-activating: clicking the widget must not pull the user out of
            // whatever they are actually working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(
            rootView: MiniView(model: model, openPanel: openPanel)
        )
        panel.level = .floating
        // Follows the user across Spaces and stays visible over full-screen apps —
        // a readout that disappears when the work does is no readout at all.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        // Key only if something inside genuinely needs it. Nothing does, so clicks
        // reach the card without the widget ever taking focus.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow follows the card's alpha, so the transparent corners outside the
        // rounded card stay free of it.
        panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = true
        panel.isRestorable = false

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSave() }
        }

        window = panel
        // Never `makeKeyAndOrderFront`: the widget appears in front of the frontmost
        // app without taking anything from it.
        panel.orderFrontRegardless()
    }

    private func destroy() {
        guard let window else { return }
        // Last chance to record where the user left it: after `close` there are no
        // bounds to read.
        flushPendingPosition()
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        moveObserver = nil
        self.window = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Position memory

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingSave = nil
                self?.rememberPosition()
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.moveDebounceMs), execute: work
        )
    }

    private func rememberPosition() {
        guard let window, let screen = screenHolding(window.frame),
              let displayId = screen.displayId
        else { return }
        positions.setPosition(window.frame.origin, for: displayId)
    }

    /// The first candidate with a remembered spot wins: the primary display, then any
    /// other attached one. A position saved on a monitor that has since been unplugged
    /// would put the window somewhere the user cannot reach it.
    private func resolveOrigin() -> NSPoint {
        let size = Layout.miniSize
        let primary = NSScreen.primaryDisplay
        let others = NSScreen.screens.filter { $0 !== primary }

        for screen in ([primary].compactMap { $0 } + others) {
            guard let displayId = screen.displayId,
                  let stored = positions.position(for: displayId)
            else { continue }
            return clamp(stored, into: screen.visibleFrame, size: size)
        }

        guard let work = primary?.visibleFrame else { return .zero }
        return NSPoint(
            x: work.maxX - size.width - Layout.miniDefaultInset,
            y: work.maxY - size.height - Layout.miniDefaultInset
        )
    }

    /// The display the window sits on, by largest overlap — a window straddling two
    /// screens belongs to the one showing most of it.
    private func screenHolding(_ frame: NSRect) -> NSScreen? {
        let best = NSScreen.screens.max { left, right in
            overlap(frame, left.frame) < overlap(frame, right.frame)
        }
        if let best, overlap(frame, best.frame) > 0 { return best }
        return window?.screen ?? NSScreen.primaryDisplay
    }

    private func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    /// Rounded to whole points and pulled back inside the work area. The minimum wins
    /// when the area is smaller than the window, which beats pushing it off the top.
    private func clamp(_ point: CGPoint, into work: NSRect, size: CGSize) -> NSPoint {
        NSPoint(
            x: max(work.minX, min(point.x.rounded(), work.maxX - size.width)),
            y: max(work.minY, min(point.y.rounded(), work.maxY - size.height))
        )
    }
}

extension NSScreen {
    /// `CGDirectDisplayID`, the only display identity that survives a reboot and a
    /// re-plug — the index in `NSScreen.screens` does not.
    var displayId: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The display the menu bar is on, which is where a first-run widget belongs.
    static var primaryDisplay: NSScreen? {
        let main = CGMainDisplayID()
        return screens.first { $0.displayId == main } ?? screens.first
    }
}
