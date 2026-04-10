#if DEBUG
import EventKit
import Foundation
import SwiftData
import SwiftUI

// MARK: - Mock Event Store

/// A mock implementation of EventReading for SwiftUI Previews.
/// Does not require calendar permissions and returns configurable fake data.
final class MockEventStore: EventReading, @unchecked Sendable {
    let mockAuthorizationStatus: EKAuthorizationStatus

    init(authorizationStatus: EKAuthorizationStatus = .fullAccess) {
        self.mockAuthorizationStatus = authorizationStatus
    }

    func requestAccess() async throws -> Bool {
        mockAuthorizationStatus == .fullAccess
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        mockAuthorizationStatus
    }

    func availableCalendars() -> [EKCalendar] { [] }

    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]?) -> [EKEvent] { [] }

    func calendar(withIdentifier identifier: String) -> EKCalendar? { nil }

    var changeNotifications: AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Preview Sync Scheduler

/// Creates a SyncScheduler suitable for Previews.
@MainActor
func previewSyncScheduler(
    lastSyncDate: Date? = nil,
    lastSyncResult: SyncResult? = nil
) -> SyncScheduler {
    let store = MockEventStore()
    let scheduler = SyncScheduler(
        eventStore: store,
        syncEngine: SyncEngine(eventStore: store)
    )
    scheduler.lastSyncDate = lastSyncDate
    scheduler.syncEngine.lastSyncResult = lastSyncResult
    return scheduler
}

// MARK: - Preview Model Container

/// Creates an in-memory ModelContainer and optionally populates it with sample data.
@MainActor
func previewModelContainer(populate: Bool = false) -> ModelContainer {
    let container = try! ModelContainer(
        for: CachedEvent.self, ServerConfiguration.self, CalendarSyncConfig.self, SyncRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    if populate {
        let context = container.mainContext
        // Server configuration
        let server = ServerConfiguration(
            serverURL: "https://cloud.example.com/remote.php/dav",
            username: "user@example.com",
            calendarPath: "/remote.php/dav/calendars/user/calmirror/",
            syncIntervalMinutes: 30,
            isActive: true
        )
        context.insert(server)

        // Calendar sync configs
        for config in PreviewData.calendarConfigs {
            context.insert(config)
        }

        // Cached events
        for event in PreviewData.cachedEvents {
            context.insert(event)
        }

        // Sync records
        for record in PreviewData.syncRecordSamples {
            context.insert(record)
        }
    }
    return container
}

// MARK: - Sample Data

enum PreviewData {
    // MARK: Calendar Configs

    static var calendarConfigs: [CalendarSyncConfig] {
        [
            CalendarSyncConfig(
                calendarIdentifier: "cal-work-001",
                calendarName: "Arbeit",
                isEnabled: true,
                isPrefixEnabled: true,
                customPrefix: "Work"
            ),
            CalendarSyncConfig(
                calendarIdentifier: "cal-personal-002",
                calendarName: "Privat",
                isEnabled: true,
                isPrefixEnabled: false
            ),
            CalendarSyncConfig(
                calendarIdentifier: "cal-birthdays-003",
                calendarName: "Geburtstage",
                isEnabled: false,
                isPrefixEnabled: true,
                customPrefix: "🎂"
            ),
        ]
    }

    // MARK: Cached Events

    static var cachedEvents: [CachedEvent] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        return [
            CachedEvent(
                eventIdentifier: "evt-001",
                calendarIdentifier: "cal-work-001",
                title: "Team Standup",
                startDate: cal.date(bySettingHour: 9, minute: 30, second: 0, of: today)!,
                endDate: cal.date(bySettingHour: 9, minute: 45, second: 0, of: today)!,
                location: "Zoom",
                notes: nil,
                isAllDay: false,
                lastModified: now,
                recurrenceRuleDescription: nil,
                remoteUID: "uid-standup-001"
            ),
            CachedEvent(
                eventIdentifier: "evt-002",
                calendarIdentifier: "cal-personal-002",
                title: "Zahnarzt",
                startDate: cal.date(bySettingHour: 14, minute: 0, second: 0, of: today)!,
                endDate: cal.date(bySettingHour: 15, minute: 0, second: 0, of: today)!,
                location: "Praxis Dr. Müller",
                notes: "Routinekontrolle",
                isAllDay: false,
                lastModified: now,
                recurrenceRuleDescription: nil,
                remoteUID: "uid-zahnarzt-002"
            ),
            CachedEvent(
                eventIdentifier: "evt-003",
                calendarIdentifier: "cal-work-001",
                title: "Sprint Planning",
                startDate: cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!)!,
                endDate: cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 11, minute: 30, second: 0, of: today)!)!,
                location: "Meeting Room A",
                notes: nil,
                isAllDay: false,
                lastModified: now,
                recurrenceRuleDescription: nil,
                remoteUID: "uid-planning-003"
            ),
            CachedEvent(
                eventIdentifier: "evt-004",
                calendarIdentifier: "cal-personal-002",
                title: "Urlaub",
                startDate: cal.date(byAdding: .day, value: 5, to: today)!,
                endDate: cal.date(byAdding: .day, value: 12, to: today)!,
                location: nil,
                notes: "Mallorca",
                isAllDay: true,
                lastModified: now,
                recurrenceRuleDescription: nil,
                remoteUID: "uid-urlaub-004"
            ),
            CachedEvent(
                eventIdentifier: "evt-005",
                calendarIdentifier: "cal-work-001",
                title: "Retrospective",
                startDate: cal.date(byAdding: .day, value: -2, to: cal.date(bySettingHour: 15, minute: 0, second: 0, of: today)!)!,
                endDate: cal.date(byAdding: .day, value: -2, to: cal.date(bySettingHour: 16, minute: 0, second: 0, of: today)!)!,
                location: nil,
                notes: nil,
                isAllDay: false,
                lastModified: cal.date(byAdding: .day, value: -3, to: now)!,
                recurrenceRuleDescription: nil,
                remoteUID: "uid-retro-005"
            ),
        ]
    }

    // MARK: Calendars

    static var calendars: [CalendarInfo] {
        [
            CalendarInfo(
                calendarIdentifier: "cal-work-001",
                title: "Arbeit",
                cgColor: CGColor(srgbRed: 0.2, green: 0.4, blue: 1.0, alpha: 1.0),
                sourceTitle: "iCloud"
            ),
            CalendarInfo(
                calendarIdentifier: "cal-personal-002",
                title: "Privat",
                cgColor: CGColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 1.0),
                sourceTitle: "iCloud"
            ),
            CalendarInfo(
                calendarIdentifier: "cal-birthdays-003",
                title: "Geburtstage",
                cgColor: CGColor(srgbRed: 1.0, green: 0.6, blue: 0.2, alpha: 1.0),
                sourceTitle: "Subscribed"
            ),
            CalendarInfo(
                calendarIdentifier: "cal-holidays-004",
                title: "Feiertage",
                cgColor: CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1.0),
                sourceTitle: "Google"
            ),
        ]
    }

    // MARK: Sync Plan Entries

    static var syncPlanEntries: [SyncPlanEntry] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        return [
            SyncPlanEntry(
                id: "entry-001",
                title: "Team Standup",
                startDate: cal.date(bySettingHour: 9, minute: 30, second: 0, of: today)!,
                endDate: cal.date(bySettingHour: 9, minute: 45, second: 0, of: today)!,
                isAllDay: false,
                calendarIdentifier: "cal-work-001",
                remoteUID: "uid-standup-001",
                status: .synced,
                prefix: "Work"
            ),
            SyncPlanEntry(
                id: "entry-002",
                title: "Zahnarzt",
                startDate: cal.date(bySettingHour: 14, minute: 0, second: 0, of: today)!,
                endDate: cal.date(bySettingHour: 15, minute: 0, second: 0, of: today)!,
                isAllDay: false,
                calendarIdentifier: "cal-personal-002",
                remoteUID: "uid-zahnarzt-002",
                status: .synced,
                prefix: nil
            ),
            SyncPlanEntry(
                id: "entry-003",
                title: "Sprint Planning",
                startDate: cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!)!,
                endDate: cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 11, minute: 30, second: 0, of: today)!)!,
                isAllDay: false,
                calendarIdentifier: "cal-work-001",
                remoteUID: "uid-planning-003",
                status: .modified,
                prefix: "Work"
            ),
            SyncPlanEntry(
                id: "entry-004",
                title: "Urlaub",
                startDate: cal.date(byAdding: .day, value: 5, to: today)!,
                endDate: cal.date(byAdding: .day, value: 12, to: today)!,
                isAllDay: true,
                calendarIdentifier: "cal-personal-002",
                remoteUID: nil,
                status: .pending,
                prefix: nil
            ),
            SyncPlanEntry(
                id: "entry-005",
                title: "Retrospective",
                startDate: cal.date(byAdding: .day, value: -2, to: cal.date(bySettingHour: 15, minute: 0, second: 0, of: today)!)!,
                endDate: cal.date(byAdding: .day, value: -2, to: cal.date(bySettingHour: 16, minute: 0, second: 0, of: today)!)!,
                isAllDay: false,
                calendarIdentifier: "cal-work-001",
                remoteUID: "uid-retro-005",
                status: .synced,
                prefix: "Work"
            ),
            SyncPlanEntry(
                id: "entry-006",
                title: "Geburtstag Lisa",
                startDate: cal.date(byAdding: .day, value: 14, to: today)!,
                endDate: cal.date(byAdding: .day, value: 15, to: today)!,
                isAllDay: true,
                calendarIdentifier: "cal-birthdays-003",
                remoteUID: nil,
                status: .pending,
                prefix: "🎂"
            ),
            SyncPlanEntry(
                id: "entry-007",
                title: "Alte Besprechung",
                startDate: cal.date(byAdding: .day, value: -10, to: cal.date(bySettingHour: 11, minute: 0, second: 0, of: today)!)!,
                endDate: cal.date(byAdding: .day, value: -10, to: cal.date(bySettingHour: 12, minute: 0, second: 0, of: today)!)!,
                isAllDay: false,
                calendarIdentifier: "cal-work-001",
                remoteUID: "uid-old-007",
                status: .pendingDelete,
                prefix: "Work"
            ),
            SyncPlanEntry(
                id: "entry-008",
                title: "Unbekanntes Server-Event",
                startDate: .distantPast,
                endDate: .distantPast,
                isAllDay: false,
                calendarIdentifier: nil,
                remoteUID: "uid-orphan-008",
                status: .orphaned,
                prefix: nil
            ),
        ]
    }

    // MARK: Sync Plans

    static var samplePlan: SyncPlan {
        SyncPlan(entries: syncPlanEntries, remoteUIDsAvailable: true, errors: [])
    }

    static var emptyPlan: SyncPlan {
        SyncPlan(entries: [], remoteUIDsAvailable: true, errors: [])
    }

    static var errorPlan: SyncPlan {
        SyncPlan(
            entries: Array(syncPlanEntries.prefix(3)),
            remoteUIDsAvailable: false,
            errors: [
                "Could not fetch remote UIDs — server returned 503",
                "Orphan detection unavailable",
            ]
        )
    }

    // MARK: Sync Results

    static var syncResults: [SyncResult] {
        let cal = Calendar.current
        let now = Date()
        return [
            SyncResult(
                created: 3, updated: 1, deleted: 0, errors: [],
                timestamp: now
            ),
            SyncResult(
                created: 0, updated: 2, deleted: 1, errors: [],
                timestamp: cal.date(byAdding: .hour, value: -2, to: now)!
            ),
            SyncResult(
                created: 1, updated: 0, deleted: 0,
                errors: ["Authentication failed: 401 Unauthorized"],
                timestamp: cal.date(byAdding: .hour, value: -5, to: now)!
            ),
            SyncResult(
                created: 0, updated: 0, deleted: 0, errors: [],
                timestamp: cal.date(byAdding: .day, value: -1, to: now)!
            ),
        ]
    }

    // MARK: Sync Records (SwiftData)

    static var syncRecordSuccess: SyncRecord {
        SyncRecord(
            timestamp: Date(),
            createdCount: 3,
            updatedCount: 1,
            deletedCount: 0,
            entries: [
                SyncRecordEntry(title: "Team Standup", changeType: .created),
                SyncRecordEntry(title: "Sprint Planning", changeType: .created),
                SyncRecordEntry(title: "Retrospective", changeType: .created),
                SyncRecordEntry(title: "Zahnarzt", changeType: .updated),
            ],
            messages: [
                SyncRecordMessage(severity: .info, text: "Starting sync: 4 PUTs, 0 DELETEs"),
                SyncRecordMessage(severity: .info, text: "Sync finished: 3 created, 1 updated"),
            ]
        )
    }

    static var syncRecordWithErrors: SyncRecord {
        SyncRecord(
            timestamp: Calendar.current.date(byAdding: .hour, value: -5, to: Date())!,
            createdCount: 1,
            updatedCount: 0,
            deletedCount: 0,
            entries: [
                SyncRecordEntry(title: "Team Standup", changeType: .created),
                SyncRecordEntry(title: "Sprint Planning", changeType: .error, errorMessage: "Authentication failed: 401 Unauthorized"),
            ],
            messages: [
                SyncRecordMessage(severity: .info, text: "Starting sync: 2 PUTs, 0 DELETEs"),
                SyncRecordMessage(severity: .error, text: "Create failed for 'Sprint Planning': Authentication failed: 401 Unauthorized"),
                SyncRecordMessage(severity: .warning, text: "Sync completed with errors"),
            ]
        )
    }

    static var syncRecordNoChanges: SyncRecord {
        SyncRecord(
            timestamp: Calendar.current.date(byAdding: .day, value: -1, to: Date())!,
            createdCount: 0,
            updatedCount: 0,
            deletedCount: 0,
            entries: [],
            messages: [
                SyncRecordMessage(severity: .info, text: "Starting sync: 0 PUTs, 0 DELETEs"),
                SyncRecordMessage(severity: .info, text: "No changes detected"),
            ]
        )
    }

    static var syncRecordSamples: [SyncRecord] {
        let cal = Calendar.current
        let now = Date()
        return [
            syncRecordSuccess,
            SyncRecord(
                timestamp: cal.date(byAdding: .hour, value: -2, to: now)!,
                createdCount: 0,
                updatedCount: 2,
                deletedCount: 1,
                entries: [
                    SyncRecordEntry(title: "Zahnarzt", changeType: .updated),
                    SyncRecordEntry(title: "Sprint Planning", changeType: .updated),
                    SyncRecordEntry(title: "Alte Besprechung", changeType: .deleted),
                ],
                messages: [
                    SyncRecordMessage(severity: .info, text: "Starting sync: 2 PUTs, 1 DELETEs"),
                    SyncRecordMessage(severity: .info, text: "Sync finished: 2 updated, 1 deleted"),
                ]
            ),
            syncRecordWithErrors,
            syncRecordNoChanges,
        ]
    }
}
#endif
