import Foundation

/// Core domain types, ported from `src/shared/types.ts`.
///
/// Every instant is UTC epoch milliseconds (`EpochMs`). Calendar days are identified
/// by a `DateKey` derived from the *local* timezone at the moment of derivation.
/// Never format or compare timestamps by string.

public enum SegmentType: String, Sendable, Codable, CaseIterable {
    case work
    case `break`
}

/// Timer lifecycle.
///
///   IDLE ──start──▶ RUNNING ──pause──▶ PAUSED ──resume──▶ RUNNING ...
///                      │                  │
///                      └──── endDay ──────┴──▶ ENDED
///
/// ENDED means "today's session is finalised". Starting again after ENDED reopens the
/// same day with a fresh work segment (the day row is un-finalised).
public enum TimerState: String, Sendable, Codable {
    case idle = "IDLE"
    case running = "RUNNING"
    case paused = "PAUSED"
    case ended = "ENDED"
}

/// A contiguous span of work or break. `endedAt == nil` means it is still open.
public struct Segment: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var dayId: Int64
    public var type: SegmentType
    public var startedAt: EpochMs
    public var endedAt: EpochMs?
    public var note: String?
    public var createdAt: EpochMs
    public var updatedAt: EpochMs

    public init(
        id: Int64, dayId: Int64, type: SegmentType,
        startedAt: EpochMs, endedAt: EpochMs? = nil, note: String? = nil,
        createdAt: EpochMs, updatedAt: EpochMs
    ) {
        self.id = id
        self.dayId = dayId
        self.type = type
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isOpen: Bool { endedAt == nil }
}

/// A day is the atomic unit. It deliberately stores **no** totals — every total is
/// derived by summing segments, so the numbers survive crashes, restarts and edits.
public struct Day: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var date: DateKey
    public var createdAt: EpochMs
    /// Set when the user presses End Day; cleared if they start again.
    public var endedAt: EpochMs?
    /// Snapshot of the daily target when the day was created, in minutes.
    public var targetMinutes: Int

    public init(
        id: Int64, date: DateKey, createdAt: EpochMs,
        endedAt: EpochMs? = nil, targetMinutes: Int
    ) {
        self.id = id
        self.date = date
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.targetMinutes = targetMinutes
    }
}

/// Derived aggregates for a single day. Never persisted.
public struct DayTotals: Equatable, Sendable {
    public var workedMs: Int64
    public var breakMs: Int64
    public var firstStartAt: EpochMs?
    public var lastEndAt: EpochMs?
    public var segmentCount: Int
    /// True when any segment on this day is still open.
    public var hasOpenSegment: Bool

    public init(
        workedMs: Int64 = 0, breakMs: Int64 = 0,
        firstStartAt: EpochMs? = nil, lastEndAt: EpochMs? = nil,
        segmentCount: Int = 0, hasOpenSegment: Bool = false
    ) {
        self.workedMs = workedMs
        self.breakMs = breakMs
        self.firstStartAt = firstStartAt
        self.lastEndAt = lastEndAt
        self.segmentCount = segmentCount
        self.hasOpenSegment = hasOpenSegment
    }
}

public struct DayDetail: Equatable, Sendable {
    public var day: Day
    /// Ordered by `startedAt` ascending.
    public var segments: [Segment]
    public var totals: DayTotals

    public init(day: Day, segments: [Segment], totals: DayTotals) {
        self.day = day
        self.segments = segments
        self.totals = totals
    }
}

/// The single source of truth pushed to every view.
///
/// The live display is computed as
///   worked = closedWorkedMs + (open is work ? now - clampedStart : 0)
/// where `clampedStart = max(open.startedAt, startOfLocalDay(now))`.
///
/// Views must call `liveTotals(snapshot, now)` on a 1 s tick rather than incrementing
/// a counter, so the display stays correct across sleep and clock changes.
public struct TimerSnapshot: Equatable, Sendable {
    public var state: TimerState
    /// The local calendar date this snapshot describes.
    public var date: DateKey
    public var dayId: Int64?
    /// Sum of segments on `date` that are already closed.
    public var closedWorkedMs: Int64
    public var closedBreakMs: Int64
    /// The one open segment, if any. At most one may exist at a time, app-wide.
    public var openSegment: Segment?
    public var firstStartAt: EpochMs?
    public var lastEndAt: EpochMs?
    /// Daily target in minutes, for the progress bar.
    public var targetMinutes: Int
    /// When the snapshot was produced.
    public var asOf: EpochMs

    public init(
        state: TimerState, date: DateKey, dayId: Int64? = nil,
        closedWorkedMs: Int64 = 0, closedBreakMs: Int64 = 0,
        openSegment: Segment? = nil, firstStartAt: EpochMs? = nil,
        lastEndAt: EpochMs? = nil, targetMinutes: Int, asOf: EpochMs
    ) {
        self.state = state
        self.date = date
        self.dayId = dayId
        self.closedWorkedMs = closedWorkedMs
        self.closedBreakMs = closedBreakMs
        self.openSegment = openSegment
        self.firstStartAt = firstStartAt
        self.lastEndAt = lastEndAt
        self.targetMinutes = targetMinutes
        self.asOf = asOf
    }
}

/// Live, tick-time totals derived from a snapshot.
public struct LiveTotals: Equatable, Sendable {
    public var workedMs: Int64
    public var breakMs: Int64
    /// 0..1+, worked / target. Not clamped — it may exceed 1.
    public var targetProgress: Double
    public var targetMs: Int64
    /// ms remaining to hit the target; negative once exceeded.
    public var remainingToTargetMs: Int64

    public init(
        workedMs: Int64, breakMs: Int64, targetProgress: Double,
        targetMs: Int64, remainingToTargetMs: Int64
    ) {
        self.workedMs = workedMs
        self.breakMs = breakMs
        self.targetProgress = targetProgress
        self.targetMs = targetMs
        self.remainingToTargetMs = remainingToTargetMs
    }
}

// MARK: - Spans

/// The minimum an interval needs for the duration, midnight-split and overlap rules.
/// Both stored `Segment`s and not-yet-saved candidates satisfy it.
public protocol Span {
    var type: SegmentType { get }
    var startedAt: EpochMs { get }
    var endedAt: EpochMs? { get }
}

extension Segment: Span {}

/// A span with no database identity yet — an edit candidate, or one piece of a
/// midnight split.
public struct SpanDraft: Span, Equatable, Sendable {
    public var type: SegmentType
    public var startedAt: EpochMs
    public var endedAt: EpochMs?

    public init(type: SegmentType, startedAt: EpochMs, endedAt: EpochMs? = nil) {
        self.type = type
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// One piece of a midnight split: a span plus the local day it now belongs to.
public struct SplitPiece: Equatable, Sendable {
    public var type: SegmentType
    public var startedAt: EpochMs
    public var endedAt: EpochMs?
    public var date: DateKey

    public init(type: SegmentType, startedAt: EpochMs, endedAt: EpochMs?, date: DateKey) {
        self.type = type
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.date = date
    }
}

// MARK: - History / aggregation

public struct DateRange: Equatable, Sendable {
    /// Inclusive.
    public var from: DateKey
    /// Inclusive.
    public var to: DateKey

    public init(from: DateKey, to: DateKey) {
        self.from = from
        self.to = to
    }
}

public struct RangeSummary: Equatable, Sendable {
    public var range: DateRange
    public var days: [DayDetail]
    public var totalWorkedMs: Int64
    public var totalBreakMs: Int64
    /// Days in the range with at least one work segment.
    public var activeDayCount: Int
    /// totalWorkedMs / activeDayCount, or 0 when there are no active days.
    public var averageWorkedMsPerActiveDay: Int64
    /// Days that met or exceeded their target.
    public var targetMetCount: Int

    public init(
        range: DateRange, days: [DayDetail],
        totalWorkedMs: Int64, totalBreakMs: Int64, activeDayCount: Int,
        averageWorkedMsPerActiveDay: Int64, targetMetCount: Int
    ) {
        self.range = range
        self.days = days
        self.totalWorkedMs = totalWorkedMs
        self.totalBreakMs = totalBreakMs
        self.activeDayCount = activeDayCount
        self.averageWorkedMsPerActiveDay = averageWorkedMsPerActiveDay
        self.targetMetCount = targetMetCount
    }
}

// MARK: - Mutations

public enum MutationErrorCode: String, Sendable, Equatable {
    case overlap
    case invalidRange = "invalid-range"
    case notFound = "not-found"
    case openSegmentConflict = "open-segment-conflict"
    case unknown
}

/// A mutation that failed for a reason the user should read, not a programmer error.
public struct MutationError: Error, Equatable, Sendable {
    public let code: MutationErrorCode
    public let message: String

    public init(code: MutationErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct CreateSegmentInput: Equatable, Sendable {
    public var type: SegmentType
    public var startedAt: EpochMs
    public var endedAt: EpochMs
    public var note: String?

    public init(type: SegmentType, startedAt: EpochMs, endedAt: EpochMs, note: String? = nil) {
        self.type = type
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
    }
}

/// Fields left `nil` are untouched. `endedAt`/`note` use a double optional so an
/// explicit `.some(nil)` can reopen a segment or clear a note — the Swift stand-in
/// for the TS `undefined` vs `null` distinction.
public struct UpdateSegmentInput: Equatable, Sendable {
    public var id: Int64
    public var type: SegmentType?
    public var startedAt: EpochMs?
    public var endedAt: EpochMs??
    public var note: String??

    public init(
        id: Int64, type: SegmentType? = nil, startedAt: EpochMs? = nil,
        endedAt: EpochMs?? = nil, note: String?? = nil
    ) {
        self.id = id
        self.type = type
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
    }
}

// MARK: - Prompts (crash recovery, idle, sleep/lock)

public enum RecoveryChoice: String, Sendable {
    case resume
    case closeAtHeartbeat = "close-at-heartbeat"
    case discard
}

/// Presented at launch when a segment was left open by a quit or crash.
public struct PendingRecovery: Equatable, Sendable {
    public var segment: Segment
    public var date: DateKey
    public var lastHeartbeatAt: EpochMs?
    /// Duration that would be kept by `closeAtHeartbeat`.
    public var recoverableMs: Int64
    /// Unaccounted time between the last heartbeat and now.
    public var gapMs: Int64

    public init(
        segment: Segment, date: DateKey, lastHeartbeatAt: EpochMs?,
        recoverableMs: Int64, gapMs: Int64
    ) {
        self.segment = segment
        self.date = date
        self.lastHeartbeatAt = lastHeartbeatAt
        self.recoverableMs = recoverableMs
        self.gapMs = gapMs
    }
}

public enum IdleChoice: String, Sendable {
    case keep
    case discard
}

public struct IdlePrompt: Equatable, Sendable, Identifiable {
    /// Correlates the prompt with its resolution; prompts are not interchangeable.
    public var id: UUID
    public var segmentId: Int64
    public var idleStartedAt: EpochMs
    public var idleMs: Int64

    public init(id: UUID, segmentId: Int64, idleStartedAt: EpochMs, idleMs: Int64) {
        self.id = id
        self.segmentId = segmentId
        self.idleStartedAt = idleStartedAt
        self.idleMs = idleMs
    }
}

public enum WakeChoice: String, Sendable {
    case resume
    case countAsBreak = "count-as-break"
}

public enum WakeReason: String, Sendable {
    case suspend
    case lockScreen = "lock-screen"
}

public struct WakePrompt: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var reason: WakeReason
    public var gapStartedAt: EpochMs
    public var gapEndedAt: EpochMs
    public var gapMs: Int64

    public init(
        id: UUID, reason: WakeReason,
        gapStartedAt: EpochMs, gapEndedAt: EpochMs, gapMs: Int64
    ) {
        self.id = id
        self.reason = reason
        self.gapStartedAt = gapStartedAt
        self.gapEndedAt = gapEndedAt
        self.gapMs = gapMs
    }
}

/// A one-off informational message surfaced in the panel.
public struct Notice: Equatable, Sendable, Identifiable {
    public enum Level: String, Sendable {
        case info
        case warning
    }

    public var id: UUID
    public var level: Level
    public var title: String
    public var body: String

    public init(id: UUID = UUID(), level: Level, title: String, body: String) {
        self.id = id
        self.level = level
        self.title = title
        self.body = body
    }
}
