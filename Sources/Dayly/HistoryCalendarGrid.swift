import SwiftUI
import DaylyKit

/// The month grid.
///
/// `densifyRange` guarantees one entry per calendar day, so the grid never has to reason
/// about which days happen to exist in the database — every cell is present and a day
/// with no row simply reads as empty. Leading and trailing blanks are computed from
/// `startOfWeek`, which is why the grid honours `weekStartsOn` without any modulo
/// arithmetic on raw weekday numbers.
/// Tall enough for the date, the total and the hairline without the grid needing a
/// scroll of its own on a six-row month.
private let historyCalendarCellHeight: CGFloat = 72

struct HistoryCalendarGrid: View {
    let range: DateRange
    let days: [DayDetail]
    let weekStartsOn: WeekStart
    let today: DateKey
    let selected: DateKey
    let onSelect: (DateKey) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 7)
    }

    var body: some View {
        let dense = densifyRange(range, days: days)
        let lead = daysBetween(
            from: startOfWeek(range.from, weekStartsOn: weekStartsOn), to: range.from
        )
        let trail = (7 - ((lead + dense.entries.count) % 7)) % 7

        VStack(spacing: Space.m) {
            LazyVGrid(columns: columns, spacing: Space.s) {
                ForEach(Array(historyWeekdayLabels(weekStartsOn: weekStartsOn).enumerated()), id: \.offset) { column, label in
                    Text(label.uppercased())
                        .font(Type.caps.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(
                            historyIsWeekendColumn(column, weekStartsOn: weekStartsOn)
                                ? Palette.fgFaint
                                : Palette.fgMuted
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.xs)
                }
            }

            LazyVGrid(columns: columns, spacing: Space.s) {
                ForEach(Array(0..<lead), id: \.self) { _ in
                    Color.clear.frame(height: historyCalendarCellHeight)
                }
                ForEach(Array(dense.entries.enumerated()), id: \.element.date) { index, entry in
                    HistoryDayCell(
                        date: entry.date,
                        detail: entry.detail,
                        isWeekend: historyIsWeekendColumn(
                            (lead + index) % 7, weekStartsOn: weekStartsOn
                        ),
                        isToday: entry.date == today,
                        isSelected: entry.date == selected,
                        onSelect: onSelect
                    )
                }
                ForEach(Array(0..<trail), id: \.self) { _ in
                    Color.clear.frame(height: historyCalendarCellHeight)
                }
            }
        }
    }
}

/// One calendar day. Clicking selects it and never changes the visible month.
private struct HistoryDayCell: View {
    let date: DateKey
    let detail: DayDetail?
    let isWeekend: Bool
    let isToday: Bool
    let isSelected: Bool
    let onSelect: (DateKey) -> Void

    @State private var isHovering = false

    private var workedMs: Int64 { detail?.totals.workedMs ?? 0 }
    /// The day's own stamped target, so a cell reports the goal that day was actually
    /// run against rather than today's preference.
    private var targetMs: Int64 { minutesToMs(detail?.day.targetMinutes ?? 0) }
    private var isMet: Bool { targetMs > 0 && workedMs >= targetMs }
    private var isTracked: Bool { workedMs > 0 }

    var body: some View {
        Button {
            onSelect(date)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(date.day))
                    .font(Type.metaTabular.weight(isToday ? .semibold : .regular))
                    .foregroundStyle(
                        isToday ? Palette.accent : (isTracked ? Palette.fgMuted : Palette.fgFaint)
                    )
                Spacer(minLength: Space.xs)
                HStack(spacing: Space.xs) {
                    Text(isTracked ? formatCompact(workedMs) : "—")
                        .font(Type.body)
                        .monospacedDigit()
                        .foregroundStyle(isTracked ? Palette.fg : Palette.fgFaint)
                    Spacer(minLength: 0)
                    if isMet {
                        Circle().fill(Palette.work).frame(width: 6, height: 6)
                    }
                }
                Spacer(minLength: Space.xs)
                progressHairline
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: historyCalendarCellHeight)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(background))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.control, value: isHovering)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(label)
    }

    private var progressHairline: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.border)
                if targetMs > 0 {
                    Capsule()
                        .fill(isMet ? Palette.work : Palette.accent)
                        .frame(
                            width: geometry.size.width
                                * min(1, Double(workedMs) / Double(targetMs))
                        )
                }
            }
        }
        .frame(height: 2)
    }

    private var background: Color {
        if isSelected { return Palette.accentSoft }
        return isWeekend ? Palette.sunken : Palette.raised
    }

    /// Hover brightens the border only — a cell that changed fill on hover would read as
    /// a second selection.
    private var border: Color {
        if isSelected { return Palette.accent }
        if isToday { return Palette.accent.opacity(0.6) }
        return isHovering ? Palette.borderStrong : Palette.border
    }

    private var label: String {
        let worked = isTracked ? "\(formatCompact(workedMs)) worked" : "nothing tracked"
        return "\(formatDateLong(date)) — \(worked)\(isMet ? ", target met" : "")"
    }
}
