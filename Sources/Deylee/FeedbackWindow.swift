import AppKit
import DeyleeKit
import Observation
import SwiftUI

/// What the person is typing, and what happened when they sent it.
@MainActor
@Observable
final class FeedbackModel {
    var text = ""
    var isSending = false
    var error: String?

    private let service: FeedbackService
    /// Called after a successful send, so the window can take itself away.
    var onSent: () -> Void = {}

    init(service: FeedbackService) {
        self.service = service
    }

    var remaining: Int { FeedbackService.maximumCharacters - text.count }
    var isOverLimit: Bool { remaining < 0 }

    var canSend: Bool {
        !isSending
            && !isOverLimit
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        guard canSend else { return }
        isSending = true
        error = nil
        Task {
            do {
                try await service.send(text.trimmingCharacters(in: .whitespacesAndNewlines))
                isSending = false
                // Cleared before the window goes, so reopening it starts blank rather
                // than showing a message that has already been sent.
                text = ""
                onSent()
            } catch {
                isSending = false
                self.error = String(describing: error)
            }
        }
    }
}

struct FeedbackView: View {
    @Bindable var model: FeedbackModel
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("What went wrong, or what would help?")
                .font(Type.body)
                .foregroundStyle(Palette.fg)

            TextEditor(text: $model.text)
                .font(Type.body)
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .background(Palette.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(model.isOverLimit ? Palette.danger : Palette.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .frame(minHeight: Layout.feedbackEditorMinHeight)
                .disabled(model.isSending)

            // Said before sending rather than after, because a person deciding what to
            // write should know what travels with it.
            Text("Sent with your Deylee version and macOS version. Nothing else — no logs, no screenshots.")
                .font(Type.meta)
                .foregroundStyle(Palette.fgFaint)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.error {
                Text(error)
                    .font(Type.meta)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.m) {
                // Only counts down near the limit; a counter on an empty box is noise.
                if model.remaining <= Layout.feedbackCounterThreshold {
                    Text("\(model.remaining)")
                        .font(Type.meta)
                        .foregroundStyle(model.isOverLimit ? Palette.danger : Palette.fgFaint)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DeyleeButtonStyle(variant: .ghost, size: .small))
                Button(model.isSending ? "Sending…" : "Send") { model.send() }
                    .buttonStyle(DeyleeButtonStyle(variant: .primary, size: .small))
                    .disabled(!model.canSend)
            }
        }
        .padding(Space.x4l)
        .frame(width: Layout.feedbackSize.width, alignment: .leading)
        .background(Palette.surface)
    }
}

/// The feedback window: a plain titled sheet of its own, and only ever one.
@MainActor
final class FeedbackWindowController: NSObject, NSWindowDelegate {
    private let model: FeedbackModel
    private var window: NSWindow?

    init(service: FeedbackService) {
        self.model = FeedbackModel(service: service)
        super.init()
        model.onSent = { [weak self] in self?.close() }
    }

    /// Whatever was typed survives a close and comes back on reopen — the window is
    /// dismissed by accident far more often than a half-written report is abandoned
    /// on purpose. It is cleared on a successful send and nowhere else.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.feedbackSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Send feedback"
        window.contentViewController = NSHostingController(
            rootView: FeedbackView(model: model, onCancel: { [weak self] in self?.close() })
        )
        window.setContentSize(Layout.feedbackSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window

        // A window that has to be typed into needs the Edit menu's shortcuts, which
        // an accessory app does not have until it becomes a regular one.
        DockPresence.acquire()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DockPresence.releaseIfLastWindow()
    }
}
