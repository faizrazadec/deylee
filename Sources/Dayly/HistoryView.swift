import SwiftUI
import DaylyKit

/// The History window.
///
/// One month is in play at a time: `monthRange(anchor)` defines the visible range and
/// both presentations plus the day panel read from the same loaded summary, so the
/// calendar and the list can never disagree.
///
/// A 60 s tick is enough to keep "today" honest across midnight without repainting the
/// whole month every second; the day panel runs its own 1 s tick because it is the only
/// part of this window that shows a running total.
struct HistoryView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = todayKey(now: context.date.epochMs)

            VStack(spacing: 0) {
                header
                if let status = model.status { banner(status) }
                HistorySummaryBar(month: model.monthSummary, week: model.weekSummary)
                main(today: today)
            }
            .background(Palette.surface)
            .foregroundStyle(Palette.fg)
        }
        .sheet(item: $model.editor) { target in
            HistorySegmentEditor(
                target: target,
                onCancel: { model.editor = nil },
                onSave: { model.save(target, $0) }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.xl) {
            HStack(spacing: Space.xs) {
                chevron("chevron.left", label: "Previous month") { model.goToPreviousMonth() }
                chevron("chevron.right", label: "Next month") { model.goToNextMonth() }
            }

            Text(historyMonthLabel(model.anchor))
                .font(Type.monthTitle)
                .foregroundStyle(Palette.fg)

            Button("Today") { model.goToToday() }
                .buttonStyle(DaylyButtonStyle(variant: .ghost, size: .small))

            Spacer(minLength: Space.xl)

            HistorySegmentedPicker(
                options: HistoryViewMode.allCases,
                label: \.label,
                accessibilityLabel: "View",
                selection: $model.view
            )

            ForEach(HistoryExportFormat.allCases, id: \.self) { format in
                Button(format.label) { model.export(format) }
                    .buttonStyle(DaylyButtonStyle(variant: .secondary, size: .small))
                    // Both are disabled while either export is in flight: the second file
                    // would be built from the same range and only confuse the banner.
                    .disabled(model.exporting != nil)
            }
        }
        .padding(.horizontal, Space.x4l)
        .padding(.vertical, Space.xl)
        .background(Palette.raised)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.border) }
    }

    private func chevron(
        _ systemName: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(DaylyButtonStyle(variant: .secondary, size: .small))
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: - Status banner

    private func banner(_ status: HistoryStatus) -> some View {
        HStack(spacing: Space.xl) {
            Text(status.text)
                .font(Type.small)
                .foregroundStyle(status.tone == .ok ? Palette.fgMuted : Palette.danger)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(status.text)
            Spacer(minLength: 0)
            Button("Dismiss") { model.status = nil }
                .buttonStyle(DaylyButtonStyle(variant: .ghost, size: .small))
        }
        .padding(.horizontal, Space.x4l)
        .padding(.vertical, Space.m)
        .background(status.tone == .ok ? Palette.sunken : Palette.dangerSoft)
        .overlay(alignment: .bottom) {
            Divider().overlay(status.tone == .ok ? Palette.border : Palette.danger.opacity(0.3))
        }
    }

    // MARK: - Main

    private func main(today: DateKey) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if model.loadFailed {
                        EmptyStateCard(
                            title: "History could not be read",
                            description: """
                                Dayly could not reach its local database. Close and reopen \
                                this window to try again.
                                """
                        )
                    } else {
                        if model.monthIsEmpty {
                            EmptyStateCard(
                                title: "Nothing tracked in \(historyMonthLabel(model.anchor))",
                                description: """
                                    Days appear here once you track time. You can still add \
                                    a segment by hand from the day panel.
                                    """
                            )
                        }

                        switch model.view {
                        case .calendar:
                            // The calendar still draws under its empty state: an empty
                            // month is a shape the user recognises, and every cell is
                            // still a place to add a segment.
                            HistoryCalendarGrid(
                                range: model.range,
                                days: model.monthSummary?.days ?? [],
                                weekStartsOn: model.weekStartsOn,
                                today: today,
                                selected: model.selected,
                                onSelect: { model.select($0) }
                            )
                        case .list:
                            if !model.monthIsEmpty {
                                HistoryListView(
                                    range: model.range,
                                    days: model.monthSummary?.days ?? [],
                                    today: today,
                                    selected: model.selected,
                                    onSelect: { model.select($0) }
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.x4l)
                .padding(.vertical, Space.x3l)
            }
            .frame(maxWidth: .infinity)

            HistoryDayPanel(
                date: model.selected,
                detail: model.selectedDetail,
                targetMinutes: model.selectedTargetMinutes,
                onAdd: { model.openCreate() },
                onEdit: { model.openEdit($0) },
                onDelete: { model.requestDelete($0) }
            )
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $model.pendingDelete) { segment in
            HistoryDeleteConfirm(
                segment: segment,
                error: model.deleteError,
                isDeleting: false,
                onCancel: { model.pendingDelete = nil },
                onConfirm: { model.confirmDelete() }
            )
        }
    }
}
