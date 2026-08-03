import AppKit
import SwiftUI

/// Tokens the modal layer needs. They belong in `DesignTokens.swift`; they live here
/// only so this surface can be dropped in without editing a shared file.
extension Palette {
    /// The wash between a modal and whatever it interrupts. Pure black rather than a
    /// palette colour: it has to read as "this is switched off" in both themes, and a
    /// tinted scrim would tint the panel underneath it.
    static let scrim = Color.black.opacity(0.45)
}

extension Layout {
    /// Modal card cap. The panel is narrower than this, so inside the panel the card is
    /// simply as wide as the padding allows; the cap is what keeps it sane if the same
    /// modal is ever hosted in a full-size window.
    static let modalMaxWidth: CGFloat = 384
    /// Blur applied to the surface behind a modal, so the eye cannot rest on the
    /// numbers it is no longer allowed to act on.
    static let modalBackdropBlur: CGFloat = 2
}

/// The panel/modal drop shadow from the design tokens.
///
/// CSS blur radius is roughly twice SwiftUI's, so the values are halved on the way in;
/// the offset carries over unchanged.
private struct ModalShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        return content.shadow(
            color: .black.opacity(isDark ? 0.5 : 0.13),
            radius: isDark ? 22 : 15,
            y: isDark ? 18 : 10
        )
    }
}

/// The shared chrome behind every modal in the app: scrim, centred card, header, body
/// and an optional footer.
///
/// `onDismiss` is the whole contract. A modal constructed without one cannot be escaped
/// or clicked away — that is how the recovery, idle and wake prompts guarantee the user
/// actually answers, rather than dismissing a question only they can answer and leaving
/// the record wrong.
struct DaylyModal<Content: View, Footer: View>: View {
    private let title: String
    private let onDismiss: (() -> Void)?
    private let content: Content
    private let footer: Footer?

    @State private var escapeMonitor: Any?

    /// Escape's virtual key code. `NSEvent` reports hardware keys, and Escape has no
    /// character to match against.
    private static var escapeKeyCode: UInt16 { 53 }

    init(
        title: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.onDismiss = onDismiss
        self.content = content()
        self.footer = footer()
    }

    init(
        title: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.title = title
        self.onDismiss = onDismiss
        self.content = content()
        self.footer = nil
    }

    var body: some View {
        ZStack {
            backdrop
            card.padding(Space.x4l)
        }
        .onAppear(perform: installEscapeMonitor)
        .onDisappear(perform: removeEscapeMonitor)
    }

    @ViewBuilder
    private var backdrop: some View {
        let surface = Palette.scrim.contentShape(Rectangle())
        if let onDismiss {
            // Mouse *down*, and only where it lands on the backdrop itself: the card sits
            // above and swallows its own presses, so a drag that begins inside the dialog
            // and ends out here cannot dismiss it. `minimumDistance: 0` is what makes the
            // press itself the trigger rather than a completed click.
            surface.gesture(DragGesture(minimumDistance: 0).onChanged { _ in onDismiss() })
        } else {
            surface
        }
    }

    private var card: some View {
        // The panel is 320 × 436, and the recovery prompt's three options with their
        // hints can outgrow it. Scrolling the body rather than letting it run off the
        // bottom is what keeps every choice reachable — a prompt that cannot be
        // dismissed and cannot be answered would trap the user.
        ViewThatFits(in: .vertical) {
            stack(scrollsBody: false)
            stack(scrollsBody: true)
        }
        .frame(maxWidth: Layout.modalMaxWidth)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.window))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.window)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .modifier(ModalShadow())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func stack(scrollsBody: Bool) -> some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            if scrollsBody {
                ScrollView { body(of: content) }
            } else {
                body(of: content)
            }
            if let footer {
                Divider().overlay(Palette.border)
                footerRow(footer)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(Type.control.weight(.semibold))
                .foregroundStyle(Palette.fg)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.x3l)
        .padding(.vertical, Space.xl)
    }

    private func body(of content: Content) -> some View {
        content
            .font(Type.control)
            .foregroundStyle(Palette.fgMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.x3l)
    }

    private func footerRow(_ footer: Footer) -> some View {
        HStack(spacing: Space.m) {
            Spacer(minLength: 0)
            // Labels keep their natural width: "Count as break" wrapping onto two lines
            // because the row is a point too narrow reads as a mistake.
            footer.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, Space.x3l)
        .padding(.vertical, Space.xl)
        .frame(maxWidth: .infinity)
        .background(Palette.sunken)
    }

    // MARK: - Escape

    private func installEscapeMonitor() {
        // A modal with no `onDismiss` is a decision the user must actually make, so
        // Escape is only wired when dismissal is allowed.
        guard let onDismiss, escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            MainActor.assumeIsolated { onDismiss() }
            // Swallowed: nothing behind the modal may act on the same keystroke.
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }
}
