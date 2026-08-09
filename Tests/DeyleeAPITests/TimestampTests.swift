import Testing

@testable import DeyleeAPI

/// `updated_at` is the client's own claim and it decides every conflict. The server
/// must not rewrite it — doing so would make every synced row look freshly edited and
/// hand each conflict to the staler device — but it must refuse an impossible one.
///
/// Untreated, `Int64.max` made a row win last-write-wins against every future edit
/// from every device, permanently, with no way back through the app.
@Suite struct FutureTimestamps {
    private let now: Int64 = 1_786_000_000_000

    @Test func honestClockSkewIsAccepted() {
        // Ordinary machines are minutes off with nobody having done anything wrong.
        // Refusing these would drop real work over a clock.
        #expect(!SyncController.claimsTheFuture(now, now: now))
        #expect(!SyncController.claimsTheFuture(now - 86_400_000, now: now), "a slow clock")
        #expect(!SyncController.claimsTheFuture(now + 120_000, now: now), "two minutes fast")
        #expect(!SyncController.claimsTheFuture(now + SyncController.futureTolerance, now: now),
                "exactly at the tolerance is still honest")
    }

    @Test func aClaimBeyondTheToleranceIsRefused() {
        #expect(SyncController.claimsTheFuture(now + SyncController.futureTolerance + 1, now: now))
        #expect(SyncController.claimsTheFuture(now + 600_000, now: now), "ten minutes fast")
        #expect(SyncController.claimsTheFuture(.max, now: now), "the row-freezing value")
    }

    /// The bound saturates. A wrap here would flip the comparison and refuse
    /// everything, which is the safe direction but the wrong answer.
    @Test func theBoundDoesNotWrapNearTheTop() {
        #expect(!SyncController.claimsTheFuture(.max, now: .max))
        #expect(!SyncController.claimsTheFuture(.max - 1, now: .max - 1))
    }
}
