import AppKit
import Observation
import SwiftUI
import DeyleeKit

// MARK: - Queue

/// One question waiting for an answer.
///
/// `id` is the dedup key. The same prompt can reach the queue twice — the recovery
/// prompt is both held at boot and re-offered when the panel opens, and the power
/// monitor can see one absence through two notifications — and asking the same question
/// twice would invite two different answers to the same stretch of time.
enum PromptQueueEntry: Identifiable, Equatable {
    case recovery(PendingRecovery)
    case idle(IdlePrompt)
    case wake(WakePrompt)

    var id: String {
        switch self {
        case .recovery(let prompt): "recovery:\(prompt.segment.id)"
        case .idle(let prompt): "idle:\(prompt.id)"
        case .wake(let prompt): "wake:\(prompt.id)"
        }
    }
}

/// The FIFO queue of prompts, and the only place a prompt choice is applied.
///
/// Prompts arrive from three independent sources and must never stack: the head of this
/// queue is the one modal on screen, and the rest wait their turn. It lives on the model
/// rather than in the panel window so a prompt raised while the panel is closed — or one
/// the user clicks away from, since the panel hides on blur — is still there when the
/// panel comes back. That is also why the Electron build's catch-up read on mount has no
/// counterpart here: the state never lived in the window to begin with.
@MainActor
@Observable
final class PromptQueue {
    private(set) var entries: [PromptQueueEntry] = []
    /// True while a choice is being written. The buttons dim rather than accept a second
    /// answer to a question that is already being applied.
    private(set) var isResolving = false

    /// The only entry that is ever rendered.
    var head: PromptQueueEntry? { entries.first }

    @ObservationIgnored private let engine: TimerEngine
    @ObservationIgnored private let repo: Repository
    /// Called whenever a prompt takes the screen, so the panel can drop a confirmation
    /// the user is no longer looking at.
    @ObservationIgnored var onPromptShown: () -> Void = {}

    init(engine: TimerEngine, repo: Repository) {
        self.engine = engine
        self.repo = repo
    }

    // MARK: Enqueue

    func enqueue(recovery: PendingRecovery) { enqueue(.recovery(recovery)) }
    func enqueue(idle: IdlePrompt) { enqueue(.idle(idle)) }
    func enqueue(wake: WakePrompt) { enqueue(.wake(wake)) }

    private func enqueue(_ entry: PromptQueueEntry) {
        // A prompt taking the screen invalidates any half-made decision underneath it:
        // answering the prompt must not reveal a stale confirmation the user has moved
        // on from.
        onPromptShown()
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
    }

    // MARK: Resolve

    func resolve(recovery choice: RecoveryChoice) {
        guard case .recovery(let pending) = head else { return }
        advance { [engine] in
            try engine.apply(planRecovery(pending, choice: choice))
        }
    }

    func resolve(idle choice: IdleChoice) {
        guard case .idle(let prompt) = head else { return }
        advance { [engine, repo] in
            // Applied to the segment the prompt described, never "whatever is open now":
            // a prompt answered late must not trim a stretch it was never about. A
            // segment that has since been deleted simply has nothing left to decide.
            guard let segment = try repo.segment(id: prompt.segmentId) else { return }
            try engine.apply(
                planIdle(segment, idleStartedAt: prompt.idleStartedAt, choice: choice)
            )
        }
    }

    func resolve(wake choice: WakeChoice) {
        guard case .wake(let prompt) = head else { return }
        advance { [engine] in
            try engine.apply(
                planWake(
                    gapStartedAt: prompt.gapStartedAt,
                    gapEndedAt: prompt.gapEndedAt,
                    choice: choice
                )
            )
        }
    }

    /// Applies a choice and drops the head.
    ///
    /// The queue advances whether or not the write landed. A failed resolution that left
    /// its modal up would be a dead end — the modal cannot be dismissed, so the user
    /// would have no way back to the timer at all.
    private func advance(_ apply: () throws -> Void) {
        guard !isResolving, !entries.isEmpty else { return }
        isResolving = true
        defer {
            isResolving = false
            entries.removeFirst()
        }
        do {
            try apply()
        } catch {
            NSLog("[deylee] prompt resolution failed: \(error)")
        }
    }
}

// MARK: - Recovery

/// Crash / unclean-quit recovery.
///
/// A segment was left open by a quit or crash. Only the user knows what happened in the
/// unaccounted gap, so all three outcomes are offered with the consequence of each spelt
/// out — and there is no dismiss, because ignoring it would leave an open segment
/// quietly counting time nobody worked.
struct RecoveryPromptView: View {
    let prompt: PendingRecovery
    let busy: Bool
    let onResolve: (RecoveryChoice) -> Void

    private struct Option {
        let choice: RecoveryChoice
        let label: String
        let hint: String
        let variant: ButtonVariant
    }

    private var options: [Option] {
        [
            Option(
                choice: .closeAtHeartbeat,
                label: "Keep \(formatCompact(prompt.recoverableMs))",
                hint: "Ends the segment at the last heartbeat and drops the unaccounted time.",
                variant: .primary
            ),
            Option(
                choice: .resume,
                label: "Resume it",
                hint: "Leaves the segment open and keeps counting from when it started.",
                variant: .secondary
            ),
            Option(
                choice: .discard,
                label: "Discard",
                hint: "Deletes the segment; none of that time is counted.",
                variant: .ghost
            ),
        ]
    }

    var body: some View {
        DeyleeModal(title: "Unfinished session") {
            VStack(alignment: .leading, spacing: Space.xxl) {
                description
                stats
                choices
            }
        }
    }

    private var description: some View {
        (
            Text("Deylee closed while a \(prompt.segment.type.rawValue) segment was still running. It started at ")
                + Text(formatClock(prompt.segment.startedAt))
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(Palette.fg)
                + Text(" on \(formatDateLong(prompt.date)).")
        )
        .lineSpacing(Space.xs)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            stat(label: "Recoverable", value: formatCompact(prompt.recoverableMs))
            stat(label: "Unaccounted", value: formatCompact(prompt.gapMs))
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.sunken))
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(label)
                .font(Type.meta)
                .foregroundStyle(Palette.fgFaint)
            Text(value)
                .font(Type.control.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Palette.fg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ForEach(options, id: \.choice.rawValue) { option in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Button(option.label) { onResolve(option.choice) }
                        .buttonStyle(DeyleeButtonStyle(variant: option.variant, fillWidth: true))
                        .disabled(busy)
                    Text(option.hint)
                        .font(Type.meta)
                        .foregroundStyle(Palette.fgFaint)
                        .lineSpacing(Space.xs)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Idle

/// Idle detection: no input for longer than the threshold while a work segment was open.
///
/// The answer is applied to the prompt's own segment, never "the segment that is open
/// now", so a prompt answered late cannot trim the wrong stretch.
struct IdlePromptView: View {
    let prompt: IdlePrompt
    let busy: Bool
    let onResolve: (IdleChoice) -> Void

    private var idleEndedAt: EpochMs { prompt.idleStartedAt + prompt.idleMs }

    var body: some View {
        DeyleeModal(title: "Away from your desk?") {
            VStack(alignment: .leading, spacing: Space.m) {
                description
                Text(
                    "Keep counts that time as work. Discard ends the segment at "
                        + "\(formatClock(prompt.idleStartedAt)) and opens a fresh one now, so the "
                        + "idle stretch is simply absent from the day."
                )
                .font(Type.meta)
                .foregroundStyle(Palette.fgFaint)
                .lineSpacing(Space.xs)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("Discard") { onResolve(.discard) }
                .buttonStyle(DeyleeButtonStyle(variant: .ghost))
                .disabled(busy)
            Button("Keep") { onResolve(.keep) }
                .buttonStyle(DeyleeButtonStyle(variant: .primary))
                .disabled(busy)
        }
    }

    private var description: some View {
        (
            Text("You were idle for ")
                + Text(formatCompact(prompt.idleMs))
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(Palette.fg)
                + Text(", from ")
                + Text(formatClock(prompt.idleStartedAt)).monospacedDigit()
                + Text(" to ")
                + Text(formatClock(idleEndedAt)).monospacedDigit()
                + Text(".")
        )
        .lineSpacing(Space.xs)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Wake

/// Sleep / lock gap.
///
/// The work segment was already closed when the machine went away, so nothing is
/// counting right now. What is still undecided is the gap itself — unrecorded, or a
/// break — and either answer starts work again from this moment.
struct WakePromptView: View {
    let prompt: WakePrompt
    let busy: Bool
    let onResolve: (WakeChoice) -> Void

    private var cause: String {
        prompt.reason == .suspend ? "This computer was asleep" : "The screen was locked"
    }

    var body: some View {
        DeyleeModal(title: "Welcome back") {
            VStack(alignment: .leading, spacing: Space.m) {
                description
                Text(
                    "Resume work leaves the gap off the record. Count as break stores it as a "
                        + "break segment. Either way, work starts again now."
                )
                .font(Type.meta)
                .foregroundStyle(Palette.fgFaint)
                .lineSpacing(Space.xs)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("Count as break") { onResolve(.countAsBreak) }
                .buttonStyle(DeyleeButtonStyle(variant: .secondary))
                .disabled(busy)
            Button("Resume work") { onResolve(.resume) }
                .buttonStyle(DeyleeButtonStyle(variant: .primary))
                .disabled(busy)
        }
    }

    private var description: some View {
        (
            Text("\(cause) for ")
                + Text(formatCompact(prompt.gapMs))
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(Palette.fg)
                + Text(", from ")
                + Text(formatClock(prompt.gapStartedAt)).monospacedDigit()
                + Text(" to ")
                + Text(formatClock(prompt.gapEndedAt)).monospacedDigit()
                + Text(". Timing stopped the moment it happened.")
        )
        .lineSpacing(Space.xs)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - End day

/// End Day finalises the day and sits right beside the primary action, so it is
/// confirmed rather than fired on a stray click. Unlike the three prompts this one is
/// dismissible: changing your mind about ending the day leaves nothing undecided.
struct EndDayConfirmView: View {
    let workedMs: Int64
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        DeyleeModal(title: "End the day?", onDismiss: onCancel) {
            (
                Text("This closes whatever is running and finalises ")
                    + Text(formatCompact(workedMs))
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(Palette.fg)
                    + Text(" of work. You can still start again afterwards — the day simply reopens.")
            )
            .lineSpacing(Space.xs)
            .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(DeyleeButtonStyle(variant: .ghost))
            Button("End day", action: onConfirm)
                .buttonStyle(DeyleeButtonStyle(variant: .danger))
        }
    }
}

// MARK: - Notices

/// A one-off message from the app itself — on macOS, the still-tracking reminder.
///
/// A banner rather than a modal because it is informational: it must never stand between
/// the user and the timer.
struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    private var tint: Color {
        switch notice.level {
        case .info: Palette.accent
        case .warning: Palette.breakColor
        }
    }

    private var fill: Color {
        switch notice.level {
        case .info: Palette.accentSoft
        case .warning: Palette.breakSoft
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(notice.title)
                    .font(Type.small.weight(.medium))
                    .foregroundStyle(Palette.fg)
                Text(notice.body)
                    .font(Type.small)
                    .foregroundStyle(Palette.fgMuted)
                    .lineSpacing(Space.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Type.small)
                    .foregroundStyle(Palette.fgFaint)
                    .padding(Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss: \(notice.title)")
            .help("Dismiss")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

/// Every live notice, newest last. Sits between the panel header and the hero.
struct NoticeStack: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: Space.m) {
            ForEach(model.notices) { notice in
                NoticeBanner(notice: notice) { model.dismiss(notice) }
            }
        }
    }
}

// MARK: - Overlay

/// The panel's modal layer: at most one thing on screen, prompts always beating the
/// end-day confirmation.
private struct PromptOverlay: ViewModifier {
    let model: AppModel

    private var prompt: PromptQueueEntry? { model.prompts.head }
    /// A queued prompt suppresses the confirmation outright, on top of clearing it as it
    /// arrives — the confirm can be raised again while a prompt is up, and stacking two
    /// modals would hide the one that must be answered.
    private var showsEndDayConfirm: Bool { model.pendingEndDayConfirm && prompt == nil }
    private var isPresented: Bool { prompt != nil || showsEndDayConfirm }

    func body(content: Content) -> some View {
        content
            // The surface behind a modal goes soft: the numbers are still there, but they
            // are not what the user is being asked about.
            .blur(radius: isPresented ? Layout.modalBackdropBlur : 0)
            .overlay {
                if let prompt {
                    modal(for: prompt)
                } else if showsEndDayConfirm {
                    endDayConfirm
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.window))
    }

    @ViewBuilder
    private func modal(for entry: PromptQueueEntry) -> some View {
        let busy = model.prompts.isResolving
        switch entry {
        case .recovery(let prompt):
            RecoveryPromptView(prompt: prompt, busy: busy) { model.prompts.resolve(recovery: $0) }
        case .idle(let prompt):
            IdlePromptView(prompt: prompt, busy: busy) { model.prompts.resolve(idle: $0) }
        case .wake(let prompt):
            WakePromptView(prompt: prompt, busy: busy) { model.prompts.resolve(wake: $0) }
        }
    }

    /// The finalised total ticks while the question is on screen, so the number the user
    /// agrees to is the number that gets stored.
    private var endDayConfirm: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            EndDayConfirmView(
                workedMs: liveTotals(model.snapshot, now: context.date.epochMs).workedMs,
                onCancel: { model.pendingEndDayConfirm = false },
                onConfirm: { model.endDay() }
            )
        }
    }
}

extension View {
    /// Adds the panel's prompt and confirmation modals above this view.
    func deyleePrompts(_ model: AppModel) -> some View {
        modifier(PromptOverlay(model: model))
    }
}
