import AppKit
import SwiftUI
import DaylyKit

/// The floating mini window's card.
///
/// A glance surface, not a control panel: the state, the live worked total in `H:MM`,
/// and the one action the current state allows. Everything else lives in the panel,
/// which a double-click opens.
///
/// The window itself is transparent, so nothing outside the rounded card may paint —
/// the corners have to read as desktop, not as a grey box.
struct MiniView: View {
    let model: AppModel
    /// Supplied by whoever owns the panel, so the mini window never has to know how
    /// the panel is anchored to the status item.
    let openPanel: () -> Void

    var body: some View {
        // Recomputed from timestamps every second rather than incremented, so the
        // total survives sleep, a clock change and midnight.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            card(live: liveTotals(model.snapshot, now: context.date.epochMs))
        }
    }

    private func card(live: LiveTotals) -> some View {
        HStack(spacing: Space.l) {
            // Hit testing is off for everything but the button: the card's backing
            // view is what moves the window and catches the double-click, and it can
            // only see a click that the drawn content does not claim first.
            StateBadge(state: model.snapshot.state, showLabel: false)
                .allowsHitTesting(false)

            Text(formatHM(live.workedMs))
                .font(Type.miniTimer)
                .tracking(-0.5)
                .foregroundStyle(Palette.fg)
                .lineLimit(1)
                .truncationMode(.tail)
                // Flexible, so a long total truncates instead of pushing the button
                // off the 180 pt card.
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

            ActionButton(state: model.snapshot.state, size: .circle, iconOnly: true) {
                model.primaryAction()
            }
            .disabled(!model.hasLoaded)
            // Claims its own clicks, which is what keeps a fast pause/resume tap from
            // also reaching the card and opening the panel.
            .contentShape(Circle())
        }
        .padding(.horizontal, Space.xl)
        .frame(width: Layout.miniSize.width, height: Layout.miniSize.height)
        .background {
            ZStack {
                MiniCardBacking(onDoubleClick: openPanel)
                Palette.raised.opacity(0.8).allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(Palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .help(tooltip(live: live))
    }

    private func tooltip(live: LiveTotals) -> String {
        let label = StateBadge.label(for: model.snapshot.state)
        let worked = formatCompact(live.workedMs)
        let breakTime = formatCompact(live.breakMs)
        return "\(label) · \(worked) worked · \(breakTime) break — double-click to open Dayly"
    }
}

/// The card's backdrop, and the only part of it that handles the mouse.
///
/// One view does both jobs on purpose: an `NSVisualEffectView` blurring the desktop
/// has to sit at the bottom of the card anyway, and putting the mouse handling there
/// means the button — drawn above it — takes its own clicks by hit testing alone,
/// with no rectangle to keep in sync.
private struct MiniCardBacking: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> MiniCardBackingView {
        let view = MiniCardBackingView()
        // Behind-window blending is what lets the desktop through; `.active` keeps the
        // blur alive while another app is frontmost, which is the whole point of a
        // window that never takes focus.
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = Radius.card
        view.layer?.masksToBounds = true
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: MiniCardBackingView, context: Context) {
        view.onDoubleClick = onDoubleClick
    }
}

final class MiniCardBackingView: NSVisualEffectView {
    var onDoubleClick: () -> Void = {}

    /// The window is deliberately never made key, so a click arrives as a first
    /// mouse; without this the card would need a click to wake up and a second one to
    /// be used.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        // `isMovableByWindowBackground` only sees clicks this view does not take, and
        // it takes every one of them — so the drag is started here instead. The call
        // runs its own tracking loop and returns on mouse-up, leaving the click count
        // intact for the second click of a double-click.
        window?.performDrag(with: event)
    }
}
