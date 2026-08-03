import SwiftUI
import DaylyKit

/// The right-hand column: one day, its totals and its segments.
///
/// Totals are recomputed here with `dayTotals` against a 1 s tick rather than read from
/// `DayDetail.totals`, because a day whose segment is still open was already stale when
/// the range was read. Every mutation is delegated upwards — this view decides *what*
/// the user asked for, never *how* it is persisted.
struct HistoryDayPanel: View {
    let date: DateKey
    /// `nil` when nothing has ever been recorded on this day.
    let detail: DayDetail?
    /// The day's own target, falling back to the current preference for an unused day.
    let targetMinutes: Int
    let onAdd: () -> Void
    let onEdit: (Segment) -> Void
    let onDelete: (Segment) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.epochMs
            let segments = detail?.segments ?? []
            let totals = dayTotals(segments, date, now: now)

            VStack(spacing: 0) {
                header(totals: totals, now: now)
                subHeader
                segmentList(segments: segments, now: now)
            }
            .frame(width: 340)
            .background(Palette.raised)
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.border).frame(width: 1)
            }
        }
    }

    // MARK: - Header

    private func header(totals: DayTotals, now: EpochMs) -> some View {
        let targetMs = minutesToMs(max(0, targetMinutes))
        let isMet = targetMs > 0 && totals.workedMs >= targetMs

        return VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.m) {
                Text(formatDateLong(date))
                    .font(Type.control.weight(.semibold))
                    .foregroundStyle(Palette.fg)
                if date == todayKey(now: now) { HistoryTodayChip() }
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(formatHM(totals.workedMs))
                    .font(Type.dayHero)
                    .foregroundStyle(Palette.fg)
                Text(caption(totals: totals, targetMs: targetMs, isMet: isMet))
                    .font(Type.small)
                    .foregroundStyle(isMet ? Palette.work : Palette.fgMuted)
                Spacer(minLength: 0)
            }

            if targetMs > 0 {
                TargetProgressBar(progress: Double(totals.workedMs) / Double(targetMs))
            }

            metaLine(totals: totals)
        }
        .padding(.horizontal, Space.x4l)
        .padding(.vertical, Space.x3l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.border) }
    }

    private func caption(totals: DayTotals, targetMs: Int64, isMet: Bool) -> String {
        if targetMs == 0 { return "worked" }
        if isMet { return "target met · +\(formatCompact(totals.workedMs - targetMs))" }
        return "of \(formatCompact(targetMs))"
    }

    private func metaLine(totals: DayTotals) -> some View {
        HStack(spacing: Space.xl) {
            Text(span(totals: totals))
            Text("\(totals.segmentCount) \(totals.segmentCount == 1 ? "segment" : "segments")")
            Text("\(formatCompact(totals.breakMs)) break")
            Spacer(minLength: 0)
        }
        .font(Type.metaTabular)
        .foregroundStyle(Palette.fgFaint)
    }

    private func span(totals: DayTotals) -> String {
        let first = totals.firstStartAt.map { formatClock($0) } ?? "—"
        let last: String
        if let lastEndAt = totals.lastEndAt {
            last = formatClock(lastEndAt)
        } else {
            last = totals.hasOpenSegment ? "now" : "—"
        }
        return "\(first) – \(last)"
    }

    // MARK: - Segments

    private var subHeader: some View {
        HStack(spacing: Space.m) {
            SectionLabel(text: "Segments")
            Spacer(minLength: 0)
            Button("Add segment", action: onAdd)
                .buttonStyle(DaylyButtonStyle(variant: .secondary, size: .small))
        }
        .padding(.horizontal, Space.x4l)
        .padding(.top, Space.x3l)
        .padding(.bottom, Space.m)
    }

    private func segmentList(segments: [Segment], now: EpochMs) -> some View {
        ScrollView {
            if segments.isEmpty {
                EmptyStateCard(
                    title: "Nothing on this day",
                    description: "Add a segment by hand to record time the timer missed."
                )
            } else {
                LazyVStack(spacing: Space.xs) {
                    ForEach(segments) { segment in
                        HistorySegmentRow(
                            segment: segment,
                            now: now,
                            onEdit: { onEdit(segment) },
                            onDelete: { onDelete(segment) }
                        )
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .padding(.horizontal, Space.x4l)
        .padding(.bottom, Space.x4l)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A segment in the day panel: the same row the panel shows, plus the edit and delete
/// actions, which stay hidden until the row is hovered so a long day stays quiet.
struct HistorySegmentRow: View {
    let segment: Segment
    let now: EpochMs
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.m) {
            TypeChip(type: segment.type).fixedSize()
            timeRange
            if let note = segment.note, !note.isEmpty {
                Text(note)
                    .font(Type.small)
                    .foregroundStyle(Palette.fgFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
            }
            Spacer(minLength: Space.xs)
            Text(formatCompact(spanDuration(segment, now: now)))
                .font(Type.control.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Palette.fg)
                .fixedSize()
            actions
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.control)
                .fill(isHovering ? Palette.hover : Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(
                    segment.isOpen ? Palette.accent.opacity(0.4) : Palette.border,
                    lineWidth: 1
                )
        )
        .onHover { isHovering = $0 }
        .animation(Motion.control, value: isHovering)
    }

    private var timeRange: some View {
        HStack(spacing: Space.xs) {
            Text(formatClock(segment.startedAt))
            Text("–")
            if let endedAt = segment.endedAt {
                Text(formatClock(endedAt))
            } else {
                // A running segment reads as a word rather than a moving clock time.
                Text("now")
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.accent)
            }
        }
        .font(Type.control)
        .monospacedDigit()
        .foregroundStyle(Palette.fgMuted)
        // The clock times are the row's spine: a long note truncates instead of
        // squeezing `09:00 – 12:00` onto two lines.
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: Space.xxs) {
            HistoryIconButton(systemName: "pencil", label: "Edit segment", action: onEdit)
            HistoryIconButton(
                systemName: "trash", label: "Delete segment",
                isDestructive: true, action: onDelete
            )
        }
        // Kept in the layout at zero opacity, so revealing them never reflows the row —
        // and so they stay reachable by keyboard and to VoiceOver, which a conditional
        // view would take away.
        .opacity(isHovering ? 1 : 0)
        .animation(Motion.control, value: isHovering)
    }
}
