import SwiftUI
import DaylyKit

/// Create or edit one segment.
///
/// The two `HH:MM` fields are combined with the day's `DateKey` into instants and sent
/// as-is. Validation — overlap, zero length, a reversed range — belongs to the store, and
/// the message it returns is what the user reads, so nothing is "corrected" here to make
/// a save succeed.
///
/// The single interpretation made locally: an end time earlier than the start means the
/// segment runs past midnight, so the end instant lands on the next day. That is stated
/// in the form rather than applied silently, because it is a guess about intent.
struct HistorySegmentEditor: View {
    let target: HistoryEditorTarget
    let onCancel: () -> Void
    /// Returns the message to show, or `nil` when the segment was stored.
    let onSave: (HistorySegmentDraft) -> String?

    @State private var type: SegmentType
    @State private var start: String
    @State private var end: String
    @State private var note: String
    @State private var error: String?
    @State private var isSaving = false

    /// Only the segment that is currently running may be left open, so only it gets the
    /// empty-end affordance.
    private var isOpenSegment: Bool { target.segment?.isOpen == true }
    private var isNew: Bool { target.segment == nil }

    private static let noteLimit = 200

    init(
        target: HistoryEditorTarget,
        onCancel: @escaping () -> Void,
        onSave: @escaping (HistorySegmentDraft) -> String?
    ) {
        self.target = target
        self.onCancel = onCancel
        self.onSave = onSave
        _type = State(initialValue: target.segment?.type ?? .work)
        _start = State(initialValue: toTimeInputValue(
            target.segment?.startedAt ?? target.defaultStartAt
        ))
        _end = State(initialValue: {
            guard let segment = target.segment else {
                return toTimeInputValue(target.defaultStartAt + MS_PER_HOUR)
            }
            return segment.endedAt.map { toTimeInputValue($0) } ?? ""
        }())
        _note = State(initialValue: target.segment?.note ?? "")
    }

    var body: some View {
        // Resolved on every render so the midnight notice appears while the user types,
        // from exactly the same computation the save uses.
        let preview = resolve()

        HistoryModalCard(title: isNew ? "Add segment" : "Edit segment") {
            VStack(alignment: .leading, spacing: Space.x3l) {
                Text(formatDateLong(target.date))
                    .font(Type.meta)
                    .foregroundStyle(Palette.fgFaint)

                typeField
                timeFields

                if case .resolved(_, _, true) = preview {
                    notice(
                        """
                        The end time is before the start, so this segment is treated as \
                        running past midnight and ends on \
                        \(formatDateLong(addDays(target.date, 1))).
                        """,
                        fill: Palette.sunken,
                        border: Palette.border
                    )
                }

                if isOpenSegment && end.isEmpty {
                    notice(
                        """
                        This segment is still running. Leave the end time empty to keep \
                        it open, or set one to close it here.
                        """,
                        fill: Palette.accentSoft,
                        border: Palette.accent.opacity(0.3)
                    )
                }

                noteField

                if let error { HistoryErrorBox(message: error) }
            }
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(DaylyButtonStyle(variant: .ghost))
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(isNew ? "Add segment" : "Save changes", action: submit)
                .buttonStyle(DaylyButtonStyle(variant: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
        }
    }

    // MARK: - Fields

    private var typeField: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            fieldLabel("Type")
            HistorySegmentedPicker(
                options: SegmentType.allCases,
                label: { $0 == .work ? "Work" : "Break" },
                tint: { $0 == .work ? Palette.work : Palette.breakColor },
                fill: { $0 == .work ? Palette.workSoft : Palette.breakSoft },
                fillWidth: true,
                accessibilityLabel: "Segment type",
                selection: Binding(get: { type }, set: { type = $0; error = nil })
            )
        }
    }

    private var timeFields: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.s) {
                fieldLabel("Start")
                timeField(text: $start, label: "Start")
            }
            VStack(alignment: .leading, spacing: Space.s) {
                fieldLabel("End")
                timeField(text: $end, label: "End")
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                fieldLabel("Note")
                Text("(optional)")
                    .font(Type.meta)
                    .foregroundStyle(Palette.fgFaint)
            }
            TextField("What was this time for?", text: $note)
                .textFieldStyle(.plain)
                .font(Type.control)
                .foregroundStyle(Palette.fg)
                .onChange(of: note) { _, next in
                    // Clamped rather than rejected: the column is free text and a paste
                    // that is slightly too long should still land.
                    if next.count > Self.noteLimit {
                        note = String(next.prefix(Self.noteLimit))
                    }
                    error = nil
                }
                .modifier(HistoryFieldChrome())
                .accessibilityLabel("Note")
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Type.meta.weight(.medium))
            .foregroundStyle(Palette.fgMuted)
    }

    private func timeField(text: Binding<String>, label: String) -> some View {
        TextField("HH:MM", text: text)
            .textFieldStyle(.plain)
            .font(Type.control)
            .monospacedDigit()
            .foregroundStyle(Palette.fg)
            .onChange(of: text.wrappedValue) { _, _ in error = nil }
            .modifier(HistoryFieldChrome())
            .accessibilityLabel(label)
    }

    private func notice(_ text: String, fill: Color, border: Color) -> some View {
        Text(text)
            .font(Type.meta)
            .foregroundStyle(Palette.fgMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(border, lineWidth: 1)
            )
    }

    // MARK: - Saving

    private func submit() {
        guard !isSaving else { return }
        switch resolve() {
        case .invalid(let message):
            error = message
        case .resolved(let startedAt, let endedAt, _):
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            isSaving = true
            error = nil
            let message = onSave(HistorySegmentDraft(
                type: type,
                startedAt: startedAt,
                endedAt: endedAt,
                note: trimmed.isEmpty ? nil : trimmed
            ))
            // A rejected save keeps the form open with its reason attached: overlap and
            // invalid-range errors are only ever reported this way.
            isSaving = false
            error = message
        }
    }

    private func resolve() -> HistoryResolvedSpan {
        resolveSegmentInstants(
            date: target.date, start: start, end: end, allowOpenEnd: isOpenSegment
        )
    }
}

/// The bordered field chrome shared by the three inputs.
private struct HistoryFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.l)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
    }
}

enum HistoryResolvedSpan {
    /// `endedAt` is `nil` only for the running segment, left deliberately open.
    case resolved(startedAt: EpochMs, endedAt: EpochMs?, overnight: Bool)
    case invalid(message: String)
}

/// Turn the form's two local times into instants on `date`.
///
/// `allowOpenEnd` exists for editing the segment that is currently running: an empty end
/// keeps it open rather than being an error.
func resolveSegmentInstants(
    date: DateKey, start: String, end: String, allowOpenEnd: Bool,
    in zone: TimeZone = .current
) -> HistoryResolvedSpan {
    guard let startedAt = fromTimeInputValue(date: date, time: start, in: zone) else {
        return .invalid(message: "Enter a start time as HH:MM.")
    }

    if end.isEmpty {
        if allowOpenEnd { return .resolved(startedAt: startedAt, endedAt: nil, overnight: false) }
        return .invalid(message: "Enter an end time as HH:MM.")
    }

    guard let sameDay = fromTimeInputValue(date: date, time: end, in: zone) else {
        return .invalid(message: "Enter an end time as HH:MM.")
    }

    // Equal instants are *not* nudged onto the next day — a zero-length segment is a real
    // mistake, and the store names it better than a guess would.
    if sameDay >= startedAt {
        return .resolved(startedAt: startedAt, endedAt: sameDay, overnight: false)
    }

    guard let nextDay = fromTimeInputValue(date: addDays(date, 1), time: end, in: zone) else {
        return .invalid(message: "Enter an end time as HH:MM.")
    }
    return .resolved(startedAt: startedAt, endedAt: nextDay, overnight: true)
}

/// Deleting is asked about first, and the question says exactly what disappears.
struct HistoryDeleteConfirm: View {
    let segment: Segment
    let error: String?
    let isDeleting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HistoryModalCard(title: "Delete this segment?") {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(
                    "This removes the \(segment.type.rawValue) segment from "
                    + "\(formatClock(segment.startedAt)) to "
                    + "\(segment.endedAt.map { formatClock($0) } ?? "now")"
                    + ". The time it recorded is gone for good."
                )
                .font(Type.control)
                .foregroundStyle(Palette.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let error { HistoryErrorBox(message: error) }
            }
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(DaylyButtonStyle(variant: .ghost))
                .keyboardShortcut(.cancelAction)
                .disabled(isDeleting)
            Button("Delete", action: onConfirm)
                .buttonStyle(DaylyButtonStyle(variant: .danger))
                .keyboardShortcut(.defaultAction)
                .disabled(isDeleting)
        }
    }
}
