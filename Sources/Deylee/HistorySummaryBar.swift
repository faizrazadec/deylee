import SwiftUI
import DeyleeKit

/// The roll-up strip under the month header.
///
/// Both figures are `RangeSummary` values: the month for the visible range, the week for
/// the selected day. The week is read as its own range rather than filtered out of the
/// month, because a week that straddles a month boundary would otherwise under-report.
struct HistorySummaryBar: View {
    /// The visible month, or `nil` while it loads.
    let month: RangeSummary?
    /// The week containing the selected day, or `nil` while it loads.
    let week: RangeSummary?

    /// Shown wherever a figure has not arrived. Never a zero — a zero is a fact, and
    /// "not read yet" is not.
    private static let placeholder = "—"

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(
                "Month",
                value: month.map { formatCompact($0.totalWorkedMs) },
                hint: month.map { "\(formatCompact($0.totalBreakMs)) break" },
                isFirst: true
            )
            stat(
                "Week",
                value: week.map { formatCompact($0.totalWorkedMs) },
                hint: week.map {
                    "\(historyShortDateLabel($0.range.from)) – \(historyShortDateLabel($0.range.to))"
                }
            )
            stat(
                "Average day",
                value: month.map { formatCompact($0.averageWorkedMsPerActiveDay) },
                hint: "across days with work"
            )
            stat(
                "Days logged",
                value: month.map { String($0.activeDayCount) },
                hint: nil
            )
            stat(
                "Target met",
                value: month.map { String($0.targetMetCount) },
                hint: month.map { "of \($0.activeDayCount) logged" }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.x4l)
        .padding(.vertical, Space.xl)
        .background(Palette.raised)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.border) }
    }

    private func stat(
        _ label: String, value: String?, hint: String?, isFirst: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            SectionLabel(text: label)
            Text(value ?? Self.placeholder)
                .font(Type.statValue)
                .foregroundStyle(Palette.fg)
            if let hint {
                Text(hint)
                    .font(Type.metaTabular)
                    .foregroundStyle(Palette.fgFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(minWidth: 0, alignment: .leading)
        .padding(.leading, isFirst ? 0 : Space.x5l)
        .padding(.trailing, Space.x5l)
        .overlay(alignment: .leading) {
            if !isFirst {
                Rectangle().fill(Palette.border).frame(width: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
