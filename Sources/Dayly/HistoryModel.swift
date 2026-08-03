import AppKit
import Observation
import UniformTypeIdentifiers
import DaylyKit

/// Which presentation of the month is on screen. Both read the same range, so they can
/// never disagree about what happened.
enum HistoryViewMode: String, CaseIterable {
    case calendar
    case list

    var label: String {
        switch self {
        case .calendar: "Calendar"
        case .list: "List"
        }
    }
}

enum HistoryExportFormat: String, CaseIterable {
    case csv
    case json

    var label: String {
        switch self {
        case .csv: "Export CSV"
        case .json: "Export JSON"
        }
    }

    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        }
    }
}

/// The export banner. Only export outcomes ever set it, and only the user clears it.
struct HistoryStatus: Equatable {
    enum Tone { case ok, error }
    let tone: Tone
    let text: String
}

/// What the segment modal is editing.
struct HistoryEditorTarget: Identifiable {
    let id = UUID()
    let date: DateKey
    /// `nil` opens the editor in create mode.
    let segment: Segment?
    /// Where a new segment's start defaults to — the day's last end, or 09:00 local.
    let defaultStartAt: EpochMs
}

/// The state behind one History window.
///
/// One range is in play at a time — the visible calendar month — and everything on
/// screen is derived from it, so the calendar, the list and the day panel are always
/// describing the same data. Nothing is patched in place after a mutation: an edit
/// re-reads the range, which is exactly what an invalidation from another window does,
/// so an edit made elsewhere lands identically.
///
/// The week is fetched as its own range rather than filtered out of the month, because
/// a week that straddles a month boundary would otherwise silently under-report.
@MainActor
@Observable
final class HistoryModel {
    private(set) var anchor: DateKey
    private(set) var selected: DateKey
    var view: HistoryViewMode = .calendar

    private(set) var monthSummary: RangeSummary?
    private(set) var weekSummary: RangeSummary?
    private(set) var loadFailed = false
    private(set) var weekStartsOn: WeekStart
    private(set) var defaultTargetMinutes: Int

    var status: HistoryStatus?
    var editor: HistoryEditorTarget?
    var pendingDelete: Segment?
    var deleteError: String?
    private(set) var exporting: HistoryExportFormat?

    /// Set by the window so the save panel can open as a sheet rather than a free
    /// floating dialog the user can lose behind the window.
    @ObservationIgnored weak var hostWindow: NSWindow?
    /// Announces which dates a local edit touched, so the panel and the status item
    /// follow. The window wires this to the engine.
    @ObservationIgnored var onMutated: ([DateKey]) -> Void = { _ in }

    @ObservationIgnored private let repo: Repository
    @ObservationIgnored private let service: HistoryService
    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private let zone: TimeZone

    init(repo: Repository, service: HistoryService, prefs: PreferencesStore, in zone: TimeZone = .current) {
        self.repo = repo
        self.service = service
        self.prefs = prefs
        self.zone = zone
        let current = prefs.getAll()
        self.weekStartsOn = current.weekStartsOn
        self.defaultTargetMinutes = hoursToMinutes(current.dailyTargetHours)
        let today = todayKey(in: zone)
        self.anchor = startOfMonth(today)
        self.selected = today
        reload()
    }

    // MARK: - Derived

    var range: DateRange { monthRange(anchor) }
    var week: DateRange { weekRange(selected, weekStartsOn: weekStartsOn) }

    /// The selected day's data, or `nil` when nothing was ever recorded on it. The
    /// selection never leaves the visible month, which is what lets this read straight
    /// out of the loaded month rather than issuing a query per click.
    var selectedDetail: DayDetail? {
        monthSummary?.days.first { $0.day.date == selected }
    }

    var monthIsEmpty: Bool {
        monthSummary.map { $0.days.isEmpty } ?? false
    }

    /// The selected day's own stamped target, falling back to the current preference for
    /// a day that has no row yet.
    var selectedTargetMinutes: Int {
        selectedDetail?.day.targetMinutes ?? defaultTargetMinutes
    }

    // MARK: - Loading

    /// Re-reads both ranges. Every mutation and every invalidation goes through here;
    /// nothing on screen is ever patched by hand.
    func reload() {
        let now = epochNow()
        do {
            monthSummary = summariseRange(range, days: try repo.range(range, now: now))
            loadFailed = false
        } catch {
            monthSummary = nil
            loadFailed = true
        }
        // A failed week read is deliberately quiet: the stat falls back to its
        // placeholder rather than claiming the whole window is broken.
        weekSummary = try? summariseRange(week, days: repo.range(week, now: now))
    }

    private func reloadWeek() {
        weekSummary = try? summariseRange(week, days: repo.range(week, now: epochNow()))
    }

    func applyPreferences(_ next: Preferences) {
        let weekChanged = next.weekStartsOn != weekStartsOn
        weekStartsOn = next.weekStartsOn
        defaultTargetMinutes = hoursToMinutes(next.dailyTargetHours)
        // A different week start moves the week the roll-up describes, so the figure has
        // to be read again rather than relabelled.
        if weekChanged { reloadWeek() }
    }

    // MARK: - Navigation

    func select(_ date: DateKey) {
        guard date != selected else { return }
        selected = date
        reloadWeek()
    }

    func goToPreviousMonth() { goToMonth(startOfMonth(addDays(anchor, -1))) }
    func goToNextMonth() { goToMonth(startOfMonth(addDays(endOfMonth(anchor), 1))) }
    func goToToday() { goToMonth(startOfMonth(todayKey(in: zone))) }

    private func goToMonth(_ monthStart: DateKey) {
        anchor = monthStart
        status = nil
        // The selection always stays inside the visible month, which is what lets the
        // day panel read its detail straight out of the loaded month.
        let today = todayKey(in: zone)
        selected = today >= monthStart && today <= endOfMonth(monthStart) ? today : monthStart
        reload()
    }

    // MARK: - Editing

    func openCreate() {
        editor = HistoryEditorTarget(
            date: selected, segment: nil, defaultStartAt: defaultStartAt
        )
    }

    func openEdit(_ segment: Segment) {
        editor = HistoryEditorTarget(
            date: selected, segment: segment, defaultStartAt: defaultStartAt
        )
    }

    /// A new segment starts where the day left off; failing that, at a plausible 09:00.
    private var defaultStartAt: EpochMs {
        selectedDetail?.totals.lastEndAt
            ?? fromTimeInputValue(date: selected, time: "09:00", in: zone)
            ?? startOfDay(selected, in: zone)
    }

    /// Writes the segment and returns `nil`, or the message the user should read.
    ///
    /// A rejected mutation leaves the editor open with its reason attached: overlap and
    /// invalid-range errors are only ever reported this way.
    func save(_ target: HistoryEditorTarget, _ draft: HistorySegmentDraft) -> String? {
        do {
            let outcome: HistoryService.Outcome
            if let segment = target.segment {
                outcome = try service.updateSegment(UpdateSegmentInput(
                    id: segment.id,
                    type: draft.type,
                    startedAt: draft.startedAt,
                    endedAt: .some(draft.endedAt),
                    note: .some(draft.note)
                ))
            } else {
                guard let endedAt = draft.endedAt else { return "Enter an end time." }
                outcome = try service.createSegment(
                    on: target.date,
                    CreateSegmentInput(
                        type: draft.type, startedAt: draft.startedAt,
                        endedAt: endedAt, note: draft.note
                    )
                )
            }

            editor = nil
            finish(outcome)
            // An overnight segment can be split onto a day the current month does not
            // show; following it out of the range would strand the panel.
            if let date = outcome.detail?.day.date, date >= range.from, date <= range.to {
                select(date)
            }
            return nil
        } catch let error as MutationError {
            return error.message
        } catch {
            return "The segment could not be saved."
        }
    }

    func requestDelete(_ segment: Segment) {
        deleteError = nil
        pendingDelete = segment
    }

    func confirmDelete() {
        guard let segment = pendingDelete else { return }
        do {
            let outcome = try service.deleteSegment(segment.id)
            pendingDelete = nil
            deleteError = nil
            finish(outcome)
        } catch let error as MutationError {
            deleteError = error.message
        } catch {
            deleteError = "The segment could not be deleted."
        }
    }

    /// Re-read, then tell everything else. The order matters only for the eye: this
    /// window repaints from its own read rather than waiting for the round trip.
    private func finish(_ outcome: HistoryService.Outcome) {
        reload()
        onMutated(outcome.affectedDates)
    }

    // MARK: - Export

    /// Serialises the visible month and asks where to put it.
    ///
    /// The file is built before the panel opens, so a database that cannot be read is
    /// reported without first making the user choose a filename for nothing.
    func export(_ format: HistoryExportFormat) {
        guard exporting == nil else { return }
        exporting = format
        status = nil

        let range = self.range
        let content: String
        do {
            let days = try repo.range(range, now: epochNow())
            content = format == .csv
                ? buildHistoryCsv(days, in: zone)
                : buildHistoryJson(days, range: range)
        } catch {
            status = HistoryStatus(tone: .error, text: describe(error))
            exporting = nil
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Dayly data"
        panel.nameFieldStringValue = "dayly-\(range.from)_to_\(range.to).\(format.rawValue)"
        panel.allowedContentTypes = [format.contentType]

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.exporting = nil
            // A cancelled save dialog is a normal outcome and is reported nowhere.
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                self.status = HistoryStatus(tone: .ok, text: "Saved to \(url.path)")
            } catch {
                self.status = HistoryStatus(tone: .error, text: self.describe(error))
            }
        }

        if let window = hostWindow {
            panel.beginSheetModal(for: window) { complete($0) }
        } else {
            panel.begin { complete($0) }
        }
    }

    /// The reason the error carries, not Cocoa's placeholder for it.
    ///
    /// DaylyKit's errors conform to `DaylyError`, so `localizedDescription` returns
    /// their own description rather than "The operation couldn't be completed."; a
    /// Cocoa error raised by the save panel or the file system keeps its own good
    /// message through the same call.
    private func describe(_ error: Error) -> String {
        let message = error.localizedDescription
        return message.isEmpty ? "The export could not be written." : message
    }
}

/// The instants and fields a resolved editor form is asking to store.
struct HistorySegmentDraft {
    let type: SegmentType
    let startedAt: EpochMs
    /// `nil` keeps the currently running segment open.
    let endedAt: EpochMs?
    let note: String?
}
