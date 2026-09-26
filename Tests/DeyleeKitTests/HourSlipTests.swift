import Foundation
import Testing
@testable import DeyleeKit

/// The rules the app checks before asking the server for an hour slip, and the shape it
/// reads back. The server enforces the same rules; these exist so the person is told
/// where they pick the dates.

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private func instant(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> EpochMs {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = berlin
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.epochMs
}

private func key(_ s: String) -> DateKey { DateKey(s)! }

@Suite struct HourSlipRange {
    private let now = instant(2026, 9, 20, 10)

    @Test func endedDaysUpToThirtyAreAllowed() {
        #expect(hourSlipRangeProblem(from: key("2026-08-21"), to: key("2026-09-19"), now: now, in: berlin) == nil)
    }

    @Test func moreThanThirtyDaysIsRefused() {
        #expect(hourSlipRangeProblem(from: key("2026-08-20"), to: key("2026-09-19"), now: now, in: berlin)
            == "An hour slip covers at most 30 days.")
    }

    @Test func aDayThatHasNotEndedIsRefused() {
        // A range running into today says when today becomes possible.
        #expect(hourSlipRangeProblem(from: key("2026-09-18"), to: key("2026-09-20"), now: now, in: berlin)
            == hourSlipTodayProblem)
        // Yesterday is still open inside its two-hour grace period.
        #expect(hourSlipRangeProblem(
            from: key("2026-09-19"), to: key("2026-09-19"), now: instant(2026, 9, 20, 1, 30), in: berlin
        ) == "An hour slip can only cover days that have ended.")
    }

    @Test func aBackwardsRangeIsRefused() {
        #expect(hourSlipRangeProblem(from: key("2026-09-19"), to: key("2026-09-10"), now: now, in: berlin)
            == "The last day can't be before the first.")
    }

    @Test func theDefaultIsTheLastSevenEndedDays() {
        let (from, to) = defaultHourSlipRange(now: now, in: berlin)
        #expect((from, to) == (key("2026-09-13"), key("2026-09-19")))
        // Before 02:00 yesterday is not over yet, so the week ends the day before.
        let early = defaultHourSlipRange(now: instant(2026, 9, 20, 1), in: berlin)
        #expect(early == (key("2026-09-12"), key("2026-09-18")))
    }
}

@Suite struct HourSlipEmail {
    @Test func masksAllButTheFirstLetterBeforeTheAt() {
        #expect(maskedEmail("faiz@example.com") == "f***@example.com")
        #expect(maskedEmail("a@b.co") == "a***@b.co")
    }

    @Test func somethingThatIsNotAnAddressRevealsNothing() {
        #expect(maskedEmail("nobody") == "***")
        #expect(maskedEmail("@example.com") == "***")
    }
}

@Suite struct HourSlipDecoding {
    /// The server's answer, verbatim in shape (SYNC_PROTOCOL.md, *Hour slips*).
    @Test func decodesTheServersAnswer() throws {
        let json = """
        {"url":"https://api.example/slip/abc","issuedAt":1790000000000,"name":null,
         "email":"a@b.co","from":"2026-09-01","to":"2026-09-02","timeZone":"Asia/Karachi",
         "claimedMs":3600000,"witnessedMs":1800000,
         "days":[{"date":"2026-09-01","claimedMs":3600000,"witnessedMs":1800000,
                  "witnessedApproximate":true}]}
        """
        let slip = try JSONDecoder().decode(HourSlip.self, from: Data(json.utf8))
        #expect(slip.name == nil)
        #expect(slip.days.first?.witnessedApproximate == true)
        #expect(slip.claimedMs == 3_600_000)
    }
}

@Suite struct HourSlipPresets {
    private let now = instant(2026, 9, 20, 10)

    @Test func eachPresetStandsForItsDays() {
        #expect(HourSlipPreset.today.range(now: now, in: berlin)! == (key("2026-09-20"), key("2026-09-20")))
        #expect(HourSlipPreset.yesterday.range(now: now, in: berlin)! == (key("2026-09-19"), key("2026-09-19")))
        #expect(HourSlipPreset.lastSevenDays.range(now: now, in: berlin)! == (key("2026-09-13"), key("2026-09-19")))
        #expect(HourSlipPreset.custom.range(now: now, in: berlin) == nil)
    }

    /// Today is offered, and refused with the reason and the moment it becomes possible.
    @Test func todaySaysWhenItCanBeUsed() {
        let (from, to) = HourSlipPreset.today.range(now: now, in: berlin)!
        #expect(hourSlipRangeProblem(from: from, to: to, now: now, in: berlin) == hourSlipTodayProblem)
    }

    @Test func yesterdayIsAllowedOnceItsGraceHasPassed() {
        let (from, to) = HourSlipPreset.yesterday.range(now: now, in: berlin)!
        #expect(hourSlipRangeProblem(from: from, to: to, now: now, in: berlin) == nil)
    }
}

@Suite struct HourSlipEndedToday {
    private let now = instant(2026, 9, 20, 10)
    private let today = key("2026-09-20")

    @Test func todayIsAllowedOnceItHasBeenEnded() {
        #expect(hourSlipRangeProblem(from: today, to: today, now: now, in: berlin,
                                     isEnded: { $0 == key("2026-09-20") }) == nil)
    }

    @Test func todayNotYetEndedSaysToEndIt() {
        #expect(hourSlipRangeProblem(from: today, to: today, now: now, in: berlin,
                                     isEnded: { _ in false }) == hourSlipTodayProblem)
    }

    /// Every unlocked day in the range must be ended, not only the last one.
    @Test func anUnendedDayInsideTheRangeIsRefused() {
        let inGrace = instant(2026, 9, 20, 1)
        #expect(hourSlipRangeProblem(
            from: key("2026-09-18"), to: today, now: inGrace, in: berlin,
            isEnded: { $0 == key("2026-09-20") }
        ) == "An hour slip can only cover days that have ended.")
    }
}
