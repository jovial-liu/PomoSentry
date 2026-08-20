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

    func testExactWebsiteRulesRejectValidButDifferentManagedBlock() throws {
        let hosts = "127.0.0.1 localhost\n"
        let youtube = try WebsiteRulesFile.replacement(existing: hosts, domains: ["youtube.com"])
        XCTAssertTrue(WebsiteRulesFile.hasExactRules(in: youtube, domains: ["youtube.com"]))
        XCTAssertFalse(WebsiteRulesFile.hasExactRules(in: youtube, domains: ["reddit.com"]))
        XCTAssertFalse(WebsiteRulesFile.hasExactRules(in: hosts, domains: ["youtube.com"]))
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

    func testAppListPoliciesBlockTheCorrectApplications() {
        XCTAssertFalse(AppListPolicy.allowlist.shouldBlock(isListed: true))
        XCTAssertTrue(AppListPolicy.allowlist.shouldBlock(isListed: false))
        XCTAssertTrue(AppListPolicy.blocklist.shouldBlock(isListed: true))
        XCTAssertFalse(AppListPolicy.blocklist.shouldBlock(isListed: false))
    }

    func testStrictInputDecisionAllowsOnlySelfListedAndNavigationTargets() {
        let listed: Set<pid_t> = [20]
        let navigation: Set<pid_t> = [30]
        XCTAssertFalse(StrictInputDecision.shouldBlock(active: false, policy: .allowlist, listedPIDs: listed, navigationPIDs: navigation, ownPID: 10, targetPID: nil))
        XCTAssertFalse(StrictInputDecision.shouldBlock(active: true, policy: .allowlist, listedPIDs: listed, navigationPIDs: navigation, ownPID: 10, targetPID: 10))
        XCTAssertFalse(StrictInputDecision.shouldBlock(active: true, policy: .allowlist, listedPIDs: listed, navigationPIDs: navigation, ownPID: 10, targetPID: 20))
        XCTAssertFalse(StrictInputDecision.shouldBlock(active: true, policy: .allowlist, listedPIDs: listed, navigationPIDs: navigation, ownPID: 10, targetPID: 30))
        XCTAssertTrue(StrictInputDecision.shouldBlock(active: true, policy: .allowlist, listedPIDs: listed, navigationPIDs: navigation, ownPID: 10, targetPID: 40))
        XCTAssertTrue(StrictInputDecision.shouldBlock(active: true, policy: .allowlist, listedPIDs: listed, navigationPIDs: navigation, ownPID: 10, targetPID: nil))
    }

    func testStrictInputDecisionUsesBlocklistWithoutBlockingNavigation() {
        let listed: Set<pid_t> = [20]
        XCTAssertTrue(StrictInputDecision.shouldBlock(active: true, policy: .blocklist, listedPIDs: listed, navigationPIDs: [30], ownPID: 10, targetPID: 20))
        XCTAssertFalse(StrictInputDecision.shouldBlock(active: true, policy: .blocklist, listedPIDs: listed, navigationPIDs: [30], ownPID: 10, targetPID: 30))
        XCTAssertFalse(StrictInputDecision.shouldBlock(active: true, policy: .blocklist, listedPIDs: listed, navigationPIDs: [30], ownPID: 10, targetPID: 40))
    }

    func testStrictInputDecisionAllowsOnlyKnownAuthorizationSurfaceDuringPreparation() {
        XCTAssertFalse(StrictInputDecision.shouldBlock(
            active: true,
            policy: .allowlist,
            listedPIDs: [],
            navigationPIDs: [],
            ownPID: 10,
            targetPID: 50,
            authorizationPIDs: [50]
        ))
        XCTAssertTrue(StrictInputDecision.shouldBlock(
            active: true,
            policy: .allowlist,
            listedPIDs: [],
            navigationPIDs: [],
            ownPID: 10,
            targetPID: 51,
            authorizationPIDs: [50]
        ))
        XCTAssertTrue(SystemAuthorizationSurface.contains(bundleIdentifier: "com.apple.SecurityAgent"))
        XCTAssertFalse(SystemAuthorizationSurface.contains(bundleIdentifier: "com.apple.Terminal"))
    }

    func testOnlyKnownSystemNavigationSurfacesReceiveNavigationExemption() {
        XCTAssertTrue(SystemNavigationSurface.contains(bundleIdentifier: "com.apple.dock"))
        XCTAssertTrue(SystemNavigationSurface.contains(bundleIdentifier: "com.apple.Spotlight"))
        XCTAssertFalse(SystemNavigationSurface.contains(bundleIdentifier: "com.apple.finder"))
        XCTAssertFalse(SystemNavigationSurface.contains(bundleIdentifier: "com.apple.systempreferences"))
        XCTAssertFalse(SystemNavigationSurface.contains(bundleIdentifier: nil))
    }

    func testSessionJournalDecodesLegacyRecordsWithoutNewSnapshotFields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "mode": "专注",
          "plannedSeconds": 1500,
          "deadline": 1000,
          "selectedTaskID": null,
          "strictApps": true,
          "strictWebsites": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let journal = try decoder.decode(SessionJournal.self, from: Data(json.utf8))
        XCTAssertNil(journal.remainingSeconds)
        XCTAssertNil(journal.strictAppConfiguration)
        XCTAssertNil(journal.websiteDomains)
    }

    func testCalendarDayStampChangesAcrossCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = Date(timeIntervalSince1970: 0)
        let next = first.addingTimeInterval(86_400)
        XCTAssertNotEqual(CalendarDayStamp.value(for: first, calendar: calendar), CalendarDayStamp.value(for: next, calendar: calendar))
    }

    func testTodayTaskVisibilityKeepsOverdueOpenTasksAndHidesOldCompletedOnes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertTrue(TaskVisibility.belongsInToday(PomodoroTask(title: "open", isDone: false, dueDate: yesterday), now: now, calendar: calendar))
        XCTAssertFalse(TaskVisibility.belongsInToday(PomodoroTask(title: "done", isDone: true, dueDate: yesterday), now: now, calendar: calendar))
        XCTAssertFalse(TaskVisibility.belongsInToday(PomodoroTask(title: "later", isDone: false, dueDate: tomorrow), now: now, calendar: calendar))
        XCTAssertTrue(TaskVisibility.belongsInToday(PomodoroTask(title: "anytime", dueDate: nil), now: now, calendar: calendar))
    }
}
