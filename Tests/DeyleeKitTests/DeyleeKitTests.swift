import Testing
@testable import DeyleeKit

@Test func versionIsSet() {
    #expect(!DeyleeKit.version.isEmpty)
}
