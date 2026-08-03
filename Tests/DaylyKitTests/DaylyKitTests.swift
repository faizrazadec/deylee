import Testing
@testable import DaylyKit

@Test func versionIsSet() {
    #expect(!DaylyKit.version.isEmpty)
}
