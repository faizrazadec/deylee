import Foundation
import Hummingbird
import HTTPTypes
import Logging

/// A fixed-window counter, in memory.
///
/// Rate limiting exists here for a reason that is not brute force, though it stops that
/// too. Every password attempt runs bcrypt at cost 12 — a quarter-second of database
/// CPU, deliberately, and the same property that makes a stolen hash expensive to crack
/// makes an unauthenticated request expensive to serve. A handful of concurrent callers
/// saturates Postgres, and sync stops for every paying customer while the one route
/// nobody can shed is the way back in.
///
/// Closing the timing channel made that worse rather than better: an unknown address
/// used to cost nothing and now costs the same quarter-second as a real one. The two
/// changes only make sense together.
///
/// ponytail: fixed window and a single process's memory. Two ceilings, both fine here
/// and neither hidden — a burst straddling a window boundary gets up to twice the
/// allowance, and a second instance would keep its own counts. Postgres-backed counters
/// or a shared cache is the upgrade when this runs more than one replica.
actor RateLimiter {
    private struct Window {
        var count: Int
        var startedAt: ContinuousClock.Instant
    }

    private var windows: [String: Window] = [:]
    private let clock = ContinuousClock()
    /// Swept opportunistically rather than on a timer: the map is only ever touched
    /// from here, and a request is the only thing that makes it grow.
    private var lastSweep: ContinuousClock.Instant

    init() {
        lastSweep = ContinuousClock().now
    }

    /// Nil when the caller may proceed. Otherwise the seconds to put in `Retry-After`.
    ///
    /// Reading does not count. `record` is what counts, so a caller can be metered on
    /// failures alone — someone signing in correctly on four devices is not an attack,
    /// and charging them for it would lock out the people who did nothing wrong.
    func secondsUntilAllowed(_ key: String, limit: Int, window: Duration) -> Int? {
        let now = clock.now
        sweepIfDue(now, window: window)

        guard let existing = windows[key], now - existing.startedAt < window,
              existing.count >= limit
        else { return nil }

        let elapsed = now - existing.startedAt
        // Rounded up, and never below one: a `Retry-After: 0` invites an immediate
        // retry that is certain to be refused again.
        let remaining = (window - elapsed) / .seconds(1)
        return max(1, Int(remaining.rounded(.up)))
    }

    /// Count one against `key`.
    func record(_ key: String, window: Duration) {
        let now = clock.now
        if var existing = windows[key], now - existing.startedAt < window {
            existing.count += 1
            windows[key] = existing
        } else {
            windows[key] = Window(count: 1, startedAt: now)
        }
    }

    private func sweepIfDue(_ now: ContinuousClock.Instant, window: Duration) {
        guard now - lastSweep > window else { return }
        lastSweep = now
        windows = windows.filter { now - $0.value.startedAt < window }
    }
}

/// Throttles the auth routes, and only those.
///
/// `/v1/sync` is authenticated and cheap by comparison; the unauthenticated routes are
/// where a stranger can spend the server's money.
///
/// The caller is identified by the forwarded header rather than by the socket. The API
/// runs behind a tunnel, so the peer address is the tunnel for every request in the
/// world and would put everybody in one bucket by accident.
///
/// A request arriving with no forwarded header shares a single bucket. The header is
/// trivially forged by anything talking to the process directly, so this is not an
/// identity to trust — it is a ceiling on damage, not an authenticator.
///
/// That shared bucket has to be generous for exactly the same reason it exists. If the
/// proxy ever stops setting the header, every customer in the world lands in it at
/// once, and a limit sized for one person would take the product down far more
/// effectively than the attack it was guarding against.
struct RateLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    let limiter: RateLimiter
    let limit: Int
    let window: Duration
    let logger: Logger

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // `/v1/sync` is here because the protocol document says it can answer 429 with
        // an authoritative `Retry-After`, and a binding contract that describes
        // behaviour the server does not have is how the next client author implements
        // a handler for a response that never arrives. The ceiling is far above honest
        // traffic — a device syncs every two minutes — so this bounds a runaway client
        // rather than metering a real one.
        guard request.uri.path.hasPrefix("/v1/auth/") || request.uri.path == "/v1/sync" else {
            return try await next(request, context)
        }

        let caller = Self.caller(of: request)
        // Every request counts here, not just failures: this bounds the work a source
        // can make the server do, and a successful sign-in costs the same bcrypt as a
        // failed one.
        if let retryAfter = await limiter.secondsUntilAllowed(
            "ip:\(caller)", limit: limit, window: window
        ) {
            logger.warning("rate limited", metadata: [
                "path": .string(request.uri.path),
                "retryAfter": .string("\(retryAfter)"),
            ])
            throw HTTPError(
                .tooManyRequests,
                headers: [.retryAfter: "\(retryAfter)"],
                message: "Too many attempts. Try again in \(retryAfter) seconds."
            )
        }
        await limiter.record("ip:\(caller)", window: window)
        return try await next(request, context)
    }

    /// Cloudflare's header first, then the standard one's first hop — the left-most
    /// entry is the original client, everything after it is a proxy.
    static func caller(of request: Request) -> String {
        if let cf = request.headers[.init("CF-Connecting-IP")!], !cf.isEmpty { return cf }
        if let forwarded = request.headers[.init("X-Forwarded-For")!],
           let first = forwarded.split(separator: ",").first
        {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return "unattributed"
    }
}
