import Foundation

/// Crash / unclean-quit recovery, ported from `src/domain/recovery.ts`.
///
/// While the timer runs, the app writes a heartbeat timestamp every 30s. If the app
/// dies, the segment stays open and the heartbeat marks the last instant we know the
/// machine was actually being used. On the next launch we surface that to the user and
/// let them decide.
///
/// This module is pure: it turns (open segment, heartbeat, now) into a description of
/// the choice, and a choice into a plan. Persisting the plan is the caller's job, which
/// keeps the decision logic testable without a database.

/// How long a gap must be before it is worth mentioning to the user.
public let RECOVERY_GAP_FLOOR_MS: Int64 = 1_000

/// Describe an open segment found at startup.
///
/// `recoverableMs` is what `closeAtHeartbeat` would keep; `gapMs` is the time between
/// the last heartbeat and now, which nobody can account for.
public func buildPendingRecovery(
    _ segment: Segment,
    lastHeartbeatAt: EpochMs?,
    now: EpochMs = epochNow(),
    in zone: TimeZone = .current
) -> PendingRecovery {
    let closeAt = resolveHeartbeatCloseInstant(segment, lastHeartbeatAt: lastHeartbeatAt, now: now)
    return PendingRecovery(
        segment: segment,
        date: dateKeyOf(segment.startedAt, in: zone),
        lastHeartbeatAt: lastHeartbeatAt,
        recoverableMs: max(0, closeAt - segment.startedAt),
        gapMs: max(0, now - closeAt)
    )
}

/// The instant `closeAtHeartbeat` would use.
///
/// Clamped into `[segment.startedAt, now]`: a missing heartbeat falls back to the
/// segment start (keeping nothing), and a heartbeat from the future — possible after a
/// backwards clock change — is pulled back to now.
public func resolveHeartbeatCloseInstant(
    _ segment: Segment,
    lastHeartbeatAt: EpochMs?,
    now: EpochMs = epochNow()
) -> EpochMs {
    guard let lastHeartbeatAt else { return segment.startedAt }
    return min(max(lastHeartbeatAt, segment.startedAt), now)
}

public enum RecoveryPlan: Equatable, Sendable {
    /// Leave the segment open and carry on timing from where it was.
    case resume(segmentId: Int64)
    /// Close it at the heartbeat, keeping the time up to that point.
    case close(segmentId: Int64, endedAt: EpochMs)
    /// Delete it entirely; the time is not counted.
    case discard(segmentId: Int64)
}

/// Turn the user's choice into a concrete plan.
///
/// `closeAtHeartbeat` degrades to `discard` when it would produce a zero-length
/// segment, because storing an empty segment would show up as a phantom row in the day
/// list.
public func planRecovery(
    _ pending: PendingRecovery,
    choice: RecoveryChoice,
    now: EpochMs = epochNow()
) -> RecoveryPlan {
    let segmentId = pending.segment.id

    switch choice {
    case .resume:
        return .resume(segmentId: segmentId)

    case .discard:
        return .discard(segmentId: segmentId)

    case .closeAtHeartbeat:
        let endedAt = resolveHeartbeatCloseInstant(
            pending.segment,
            lastHeartbeatAt: pending.lastHeartbeatAt,
            now: now
        )
        if endedAt <= pending.segment.startedAt {
            return .discard(segmentId: segmentId)
        }
        return .close(segmentId: segmentId, endedAt: endedAt)
    }
}

/// Whether an open segment found at startup is worth prompting about at all.
///
/// A segment opened seconds before the app died — for example a start immediately
/// followed by a crash — carries no meaningful time, so it is silently discarded rather
/// than interrupting the user with a dialog.
public func isRecoveryWorthPrompting(_ pending: PendingRecovery) -> Bool {
    pending.recoverableMs >= RECOVERY_GAP_FLOOR_MS || pending.gapMs >= RECOVERY_GAP_FLOOR_MS
}

// MARK: - Idle time

/// Applying an idle decision to the open work segment.
///
/// `keep` leaves the segment untouched. `discard` closes it at the instant the user
/// went idle and opens a fresh segment now, so the idle stretch is simply absent from
/// the record rather than being recorded as a break.
public enum IdlePlan: Equatable, Sendable {
    case keep
    case trim(segmentId: Int64, endedAt: EpochMs, resumeAt: EpochMs)
}

public func planIdle(
    _ segment: Segment,
    idleStartedAt: EpochMs,
    choice: IdleChoice,
    now: EpochMs = epochNow()
) -> IdlePlan {
    if choice == .keep { return .keep }

    let endedAt = min(max(idleStartedAt, segment.startedAt), now)
    if endedAt <= segment.startedAt {
        // The whole segment was idle; trimming it to nothing is not representable, so
        // keep the segment and let the user delete it manually if they want to.
        return .keep
    }
    return .trim(segmentId: segment.id, endedAt: endedAt, resumeAt: now)
}

// MARK: - Sleep / lock gaps

/// Applying a wake decision to a segment that was auto-paused on sleep or lock.
///
/// The work segment was already closed at `gapStartedAt` when the machine went away.
/// On wake the user chooses what the gap itself was:
///  - `resume`       — the gap is not recorded at all; a new work segment starts now.
///  - `countAsBreak` — the gap becomes a break segment, then work starts now.
public enum WakePlan: Equatable, Sendable {
    case resumeWork(workStartsAt: EpochMs)
    case recordBreak(breakStartedAt: EpochMs, breakEndedAt: EpochMs, workStartsAt: EpochMs)
}

public func planWake(
    gapStartedAt: EpochMs,
    gapEndedAt: EpochMs,
    choice: WakeChoice
) -> WakePlan {
    if choice == .resume || gapEndedAt <= gapStartedAt {
        return .resumeWork(workStartsAt: gapEndedAt)
    }
    return .recordBreak(
        breakStartedAt: gapStartedAt,
        breakEndedAt: gapEndedAt,
        workStartsAt: gapEndedAt
    )
}
