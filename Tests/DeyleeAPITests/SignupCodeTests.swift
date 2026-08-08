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

    /// "042931" must not arrive as "42931". The code is text from the moment it is
    /// made to the moment it is typed back, and a round trip through an integer
    /// anywhere in between silently breaks one code in ten.
    @Test func keepsLeadingZeros() throws {
        // Drawn rather than contrived, so the formatting is what is under test.
        // One code in ten starts with a zero, so 20,000 draws finding none would
        // mean the padding is gone, not that the run was unlucky.
        let withLeadingZero = (0..<20_000)
            .lazy
            .map { _ in SignupCode.generate() }
            .first { $0.hasPrefix("0") }

        let code = try #require(withLeadingZero)
        #expect(code.count == 6)
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
        #expect(lowest < 50_000)
        #expect(highest > 950_000)
    }
}
