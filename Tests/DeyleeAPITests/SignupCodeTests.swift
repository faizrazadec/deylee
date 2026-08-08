import Foundation
import Testing

@testable import DeyleeAPI

/// The code itself.
///
/// Everything else about sign-up verification lives in SQL and is exercised by
/// `scripts/smoke-auth.sh` against a real database — the attempt cap and the expiry
/// are transaction behaviour, and a mock would only prove the mock works. What is
/// worth pinning here is the shape of the digits, because both failures are silent:
/// a code that loses a leading zero is rejected by a server that generated it, and a
/// biased draw shrinks the space a guesser has to cover.
@Suite struct SignupCodes {
    @Test func isAlwaysSixDigits() {
        for _ in 0..<2_000 {
            let code = SignupCode.generate()
            // Bound outside the macro: #expect re-expands the expression, and a
            // key-path predicate inside it trips the macro's rethrows analysis.
            let digitsOnly = code.allSatisfy { $0.isNumber }
            #expect(code.count == 6)
            #expect(digitsOnly)
        }
    }

    /// No code may begin with a zero. The Resend template types `otp` as a number,
    /// and a number cannot carry one: "042931" would be mailed as "42931" and then
    /// refused by the server that generated it, for one code in ten.
    ///
    /// 20,000 draws is far past the point where a surviving zero would be bad luck —
    /// under the old range roughly 2,000 of them would start with one.
    @Test func neverStartsWithZero() {
        let leadingZero = (0..<20_000)
            .lazy
            .map { _ in SignupCode.generate() }
            .first { $0.hasPrefix("0") }

        #expect(leadingZero == nil)
    }

    /// A code must survive the round trip the mailer puts it through — parsed to an
    /// integer and rendered back. That is the exact equality `Mailer` guards on, so
    /// a generator change that broke it would fail here rather than in production.
    @Test func survivesTheRoundTripThroughAnInteger() throws {
        for _ in 0..<2_000 {
            let code = SignupCode.generate()
            let value = try #require(Int(code))
            #expect(String(value) == code)
        }
    }

    /// Every digit position should reach both ends of its range. A modulo-folded
    /// draw would skew the leading digit in particular.
    @Test func coversTheWholeRange() {
        var lowest = 999_999
        var highest = 0
        for _ in 0..<20_000 {
            let value = Int(SignupCode.generate())!
            lowest = min(lowest, value)
            highest = max(highest, value)
        }
        // The floor is 100,000 now, not zero, so the low bound moves with it.
        #expect(lowest < 150_000)
        #expect(highest > 950_000)
    }
}
