import Foundation
import SwiftData

// MARK: - Schema V1 (Baseline)

enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CachedEvent.self, ServerConfiguration.self, CalendarSyncConfig.self]
    }

    @Model
    final class CachedEvent {
        @Attribute(.unique) var eventIdentifier: String
        var calendarIdentifier: String
        var title: String
        var startDate: Date
        var endDate: Date
        var location: String?
        var notes: String?
        var isAllDay: Bool
        var lastModified: Date
        var recurrenceRuleDescription: String?
        var contentHash: String
        var remoteUID: String
        var lastSyncedAt: Date

        init(
            eventIdentifier: String,
            calendarIdentifier: String,
            title: String,
            startDate: Date,
            endDate: Date,
            location: String?,
            notes: String?,
            isAllDay: Bool,
            lastModified: Date,
            recurrenceRuleDescription: String?,
            remoteUID: String
        ) {
            self.eventIdentifier = eventIdentifier
            self.calendarIdentifier = calendarIdentifier
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.location = location
            self.notes = notes
            self.isAllDay = isAllDay
            self.lastModified = lastModified
            self.recurrenceRuleDescription = recurrenceRuleDescription
            self.remoteUID = remoteUID
            self.contentHash = CachedEvent.computeHash(
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                isAllDay: isAllDay,
                recurrenceRuleDescription: recurrenceRuleDescription
            )
            self.lastSyncedAt = Date()
        }
    }

    @Model
    final class ServerConfiguration {
        @Attribute(.unique) var id: String
        var serverURL: String
        var username: String
        var calendarPath: String
        var syncIntervalMinutes: Int
        var isActive: Bool

        init(
            serverURL: String = "",
            username: String = "",
            calendarPath: String = "/calendars/",
            syncIntervalMinutes: Int = 30,
            isActive: Bool = true
        ) {
            self.id = UUID().uuidString
            self.serverURL = serverURL
            self.username = username
            self.calendarPath = calendarPath
            self.syncIntervalMinutes = syncIntervalMinutes
            self.isActive = isActive
        }
    }

    @Model
    final class CalendarSyncConfig {
        @Attribute(.unique) var calendarIdentifier: String
        var calendarName: String
        var isEnabled: Bool
        var isPrefixEnabled: Bool
        var customPrefix: String?
        var pastValue: Int
        var pastUnit: String
        var futureValue: Int
        var futureUnit: String

        init(
            calendarIdentifier: String,
            calendarName: String,
            isEnabled: Bool = false,
            isPrefixEnabled: Bool = false,
            customPrefix: String? = nil,
            pastValue: Int = 1,
            pastUnit: String = "weekOfYear",
            futureValue: Int = 1,
            futureUnit: String = "year"
        ) {
            self.calendarIdentifier = calendarIdentifier
            self.calendarName = calendarName
            self.isEnabled = isEnabled
            self.isPrefixEnabled = isPrefixEnabled
            self.customPrefix = customPrefix
            self.pastValue = pastValue
            self.pastUnit = pastUnit
            self.futureValue = futureValue
            self.futureUnit = futureUnit
        }
    }
}

// MARK: - Schema V2 (Adds SyncRecord)

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CachedEvent.self, ServerConfiguration.self, CalendarSyncConfig.self, SyncRecord.self]
    }
}

// MARK: - Migration Plan

enum CalMirrorMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )
}
