import SwiftUI
import DeyleeKit

/// The month as rows instead of a grid.
///
/// It covers the same densified range as the calendar, so the two views never disagree
/// about which days exist, but runs newest first — scanning a log backwards from today
/// is what a list is for.
struct HistoryListView: View {
    let range: DateRange
    let days: [DayDetail]
    let today: DateKey
    let selected: DateKey
    let onSelect: (DateKey) -> Void

    var body: some View {
        let rows = densifyRange(range, days: days).entries.reversed()

        VStack(spacing: 0) {
            header
            LazyVStack(spacing: 0) {
                ForEach(Array(rows), id: \.date) { entry in
                    HistoryListRow(
                        date: entry.date,
                        detail: entry.detail,
                        isToday: entry.date == today,
                        isSelected: entry.date == selected,
                        onSelect: onSelect
                    )
                }
            }
            .padding(.top, Space.xs)
        }
    }

    private var header: some View {
        HStack(spacing: Space.xl) {
            SectionLabel(text: "Day")
                .frame(maxWidth: .infinity, alignment: .leading)
            SectionLabel(text: "Worked")
                .frame(width: historyListNumberColumn, alignment: .trailing)
            SectionLabel(text: "Break")
                .frame(width: historyListNumberColumn, alignment: .trailing)
            SectionLabel(text: "First")
                .frame(width: historyListClockColumn, alignment: .trailing)
            SectionLabel(text: "Last")
                .frame(width: historyListClockColumn, alignment: .trailing)
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.m)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.border) }
    }
}

private let historyListNumberColumn: CGFloat = 88
private let historyListClockColumn: CGFloat = 72

private struct HistoryListRow: View {
    let date: DateKey
    let detail: DayDetail?
    let isToday: Bool
    let isSelected: Bool
    let onSelect: (DateKey) -> Void

    @State private var isHovering = false

    private var workedMs: Int64 { detail?.totals.workedMs ?? 0 }
    private var breakMs: Int64 { detail?.totals.breakMs ?? 0 }
    private var targetMs: Int64 { minutesToMs(detail?.day.targetMinutes ?? 0) }
    private var isMet: Bool { targetMs > 0 && workedMs >= targetMs }
    /// A day with nothing but a break still happened, so the list counts it as tracked.
    /// The calendar deliberately does not: a green-dotted grid is about work.
    private var isTracked: Bool { workedMs > 0 || breakMs > 0 }

    var body: some View {
        Button {
            onSelect(date)
        } label: {
            HStack(spacing: Space.xl) {
                day
                worked
                Text(breakMs > 0 ? formatCompact(breakMs) : "—")
                    .foregroundStyle(breakMs > 0 ? Palette.breakColor : Palette.fgFaint)
                    .frame(width: historyListNumberColumn, alignment: .trailing)
                Text(detail?.totals.firstStartAt.map { formatClock($0) } ?? "—")
                    .frame(width: historyListClockColumn, alignment: .trailing)
                Text(lastLabel)
                    .frame(width: historyListClockColumn, alignment: .trailing)
            }
            .font(Type.control)
            .monospacedDigit()
            .foregroundStyle(isSelected ? Palette.fg : Palette.fgMuted)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.control, value: isHovering)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var day: some View {
        HStack(spacing: Space.m) {
            Text(formatDateLong(date))
                .foregroundStyle(isTracked ? Palette.fg : Palette.fgFaint)
                .lineLimit(1)
            if isToday { HistoryTodayChip() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var worked: some View {
        HStack(spacing: Space.s) {
            Spacer(minLength: 0)
            if isMet {
                Circle().fill(Palette.work).frame(width: 6, height: 6)
            }
            Text(workedMs > 0 ? formatCompact(workedMs) : "—")
                .fontWeight(workedMs > 0 ? .medium : .regular)
                .foregroundStyle(workedMs > 0 ? Palette.fg : Palette.fgFaint)
        }
        .frame(width: historyListNumberColumn, alignment: .trailing)
    }

    /// A day whose segment is still open has no last end yet — it reads as a word rather
    /// than a clock time that would be wrong a second later.
    private var lastLabel: String {
        if let lastEndAt = detail?.totals.lastEndAt { return formatClock(lastEndAt) }
        return detail?.totals.hasOpenSegment == true ? "now" : "—"
    }

    private var background: Color {
        if isSelected { return Palette.accentSoft }
        return isHovering ? Palette.hover : .clear
    }
}
