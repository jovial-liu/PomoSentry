import Foundation
import XCTest
@testable import FanqieZhong

final class PomoSentryCoreTests: XCTestCase {
    func testDomainNormalizationAcceptsURLsAndRejectsMalformedLabels() {
        XCTAssertEqual(WebsiteRulesFile.normalizedDomain("https://WWW.YouTube.com/watch?v=1"), "youtube.com")
        XCTAssertEqual(WebsiteRulesFile.normalizedDomain("m.youtube.com/path"), "m.youtube.com")
        XCTAssertNil(WebsiteRulesFile.normalizedDomain("-bad.example.com"))
        XCTAssertNil(WebsiteRulesFile.normalizedDomain("bad..example.com"))
        XCTAssertNil(WebsiteRulesFile.normalizedDomain("example"))
        XCTAssertNil(WebsiteRulesFile.normalizedDomain("example.com\n0.0.0 bank.test"))
    }

    func testHostsApplyAndClearPreserveUnrelatedContent() throws {
        let original = "127.0.0.1 localhost\n10.0.0.5 internal.test\n"
        let applied = try WebsiteRulesFile.replacement(existing: original, domains: ["youtube.com"])
        XCTAssertTrue(WebsiteRulesFile.hasValidRules(in: applied))
        XCTAssertTrue(applied.contains("10.0.0.5 internal.test"))
        XCTAssertTrue(applied.contains("0.0.0.0 youtube.com"))

        let cleared = try WebsiteRulesFile.replacement(existing: applied, domains: [])
        XCTAssertFalse(WebsiteRulesFile.containsAnyMarker(in: cleared))
        XCTAssertEqual(cleared, original)
    }

    func testMalformedOrDuplicateMarkersAreRejectedWithoutReinterpretation() {
        let missingEnd = "127.0.0.1 localhost\n# BEGIN POMOSENTRY\n0.0.0.0 example.com\n"
        let duplicate = "# BEGIN POMOSENTRY\n# END POMOSENTRY\n# BEGIN POMOSENTRY\n# END POMOSENTRY\n"
        XCTAssertThrowsError(try WebsiteRulesFile.replacement(existing: missingEnd, domains: []))
        XCTAssertThrowsError(try WebsiteRulesFile.replacement(existing: duplicate, domains: []))
    }

    func testCountdownUsesDeadlineAndFinishesAtZero() {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = start.addingTimeInterval(60)
        XCTAssertEqual(Countdown.remaining(deadline: deadline, now: start), 60)
        XCTAssertEqual(Countdown.remaining(deadline: deadline, now: start.addingTimeInterval(37.2)), 23)
        XCTAssertEqual(Countdown.remaining(deadline: deadline, now: deadline), 0)
        XCTAssertEqual(Countdown.remaining(deadline: deadline, now: deadline.addingTimeInterval(10)), 0)
    }
}
