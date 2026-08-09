import Foundation

/// How long to wait before trying a failed sync again.
///
/// The schedule used to be a flat 120 seconds whatever happened, plus every wake and
/// every app activation. Against a server that is down — or a network that is not
/// there — that is a client hammering at full rate for as long as the outage lasts,
/// multiplied by every install. `SYNC_PROTOCOL.md` asks for exponential backoff with
/// jitter on a 5xx and this is it.
///
/// Jitter matters more than the exponent here. An outage stops every client at once,
/// so without it they all come back at the same instant and the first thing the
/// recovering server sees is the whole fleet in lockstep — the outage's own echo.
///
/// - Parameters:
///   - failures: consecutive failures, 1 for the first.
///   - base: the ordinary interval between syncs.
///   - cap: the longest wait. Ten minutes, because the person may have fixed their
///     network and be waiting; a wait long enough to be tidy is long enough to look
///     broken.
///   - random: injectable so the jitter can be pinned in a test.
public func syncRetryDelay(
    afterFailures failures: Int,
    base: TimeInterval = 120,
    cap: TimeInterval = 600,
    random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
) -> TimeInterval {
    guard failures > 0 else { return 0 }

    // Doubling, computed in the exponent rather than by multiplying in a loop, and
    // clamped before it is ever a Double large enough to lose precision. `min` on the
    // shift count is what keeps `1 << n` from overflowing on a long outage — a client
    // left running for a week reaches failure counts that would otherwise trap.
    let doublings = min(failures - 1, 16)
    let backoff = min(base * Double(1 << doublings), cap)

    // Full jitter across the range rather than a small wobble around the target. It
    // spreads a fleet evenly instead of merely blurring the edges of the thundering
    // herd, and the average wait is halved, which the person waiting will prefer.
    return random(0...backoff)
}
