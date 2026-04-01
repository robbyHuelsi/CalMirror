import Testing
import Foundation
@testable import CalMirror

struct ICSGeneratorTests {

    @Test func hashConsistency() {
        let hash1 = CachedEvent.computeHash(
            title: "Meeting",
            startDate: Date(timeIntervalSince1970: 1000000),
            endDate: Date(timeIntervalSince1970: 1003600),
            location: "Office",
            notes: "Discuss project",
            isAllDay: false,
            recurrenceRuleDescription: nil
        )

        let hash2 = CachedEvent.computeHash(
            title: "Meeting",
            startDate: Date(timeIntervalSince1970: 1000000),
            endDate: Date(timeIntervalSince1970: 1003600),
            location: "Office",
            notes: "Discuss project",
            isAllDay: false,
            recurrenceRuleDescription: nil
        )

        #expect(hash1 == hash2)
    }

    @Test func hashChangeOnTitleDifference() {
        let hash1 = CachedEvent.computeHash(
            title: "Meeting A",
            startDate: Date(timeIntervalSince1970: 1000000),
            endDate: Date(timeIntervalSince1970: 1003600),
            location: nil,
            notes: nil,
            isAllDay: false,
            recurrenceRuleDescription: nil
        )

        let hash2 = CachedEvent.computeHash(
            title: "Meeting B",
            startDate: Date(timeIntervalSince1970: 1000000),
            endDate: Date(timeIntervalSince1970: 1003600),
            location: nil,
            notes: nil,
            isAllDay: false,
            recurrenceRuleDescription: nil
        )

        #expect(hash1 != hash2)
    }

    @Test func hashChangeOnDateDifference() {
        let hash1 = CachedEvent.computeHash(
            title: "Meeting",
            startDate: Date(timeIntervalSince1970: 1000000),
            endDate: Date(timeIntervalSince1970: 1003600),
            location: nil,
            notes: nil,
            isAllDay: false,
            recurrenceRuleDescription: nil
        )

        let hash2 = CachedEvent.computeHash(
            title: "Meeting",
            startDate: Date(timeIntervalSince1970: 2000000),
            endDate: Date(timeIntervalSince1970: 2003600),
            location: nil,
            notes: nil,
            isAllDay: false,
            recurrenceRuleDescription: nil
        )

        #expect(hash1 != hash2)
    }
}

struct CalendarSyncConfigTests {

    @Test func effectivePrefixWhenDisabled() {
        let config = CalendarSyncConfig(
            calendarIdentifier: "test",
            calendarName: "Work",
            isPrefixEnabled: false,
            customPrefix: "Custom"
        )
        #expect(config.effectivePrefix == nil)
    }

    @Test func effectivePrefixUsesCustomWhenSet() {
        let config = CalendarSyncConfig(
            calendarIdentifier: "test",
            calendarName: "Work",
            isPrefixEnabled: true,
            customPrefix: "Custom"
        )
        #expect(config.effectivePrefix == "Custom")
    }

    @Test func effectivePrefixFallsBackToCalendarName() {
        let config = CalendarSyncConfig(
            calendarIdentifier: "test",
            calendarName: "Work",
            isPrefixEnabled: true,
            customPrefix: nil
        )
        #expect(config.effectivePrefix == "Work")
    }

    @Test func effectivePrefixFallsBackWhenCustomIsEmpty() {
        let config = CalendarSyncConfig(
            calendarIdentifier: "test",
            calendarName: "Work",
            isPrefixEnabled: true,
            customPrefix: ""
        )
        #expect(config.effectivePrefix == "Work")
    }
}

struct SyncResultTests {

    @Test func summaryNoChanges() {
        let result = SyncResult()
        #expect(result.summary == "No changes")
    }

    @Test func summaryWithChanges() {
        let result = SyncResult(created: 2, updated: 1, deleted: 3)
        #expect(result.summary == "2 created, 1 updated, 3 deleted")
    }

    @Test func summaryWithErrors() {
        let result = SyncResult(errors: ["Error 1", "Error 2"])
        #expect(result.summary == "2 errors")
    }

    @Test func totalChanges() {
        let result = SyncResult(created: 1, updated: 2, deleted: 3)
        #expect(result.totalChanges == 6)
    }
}
