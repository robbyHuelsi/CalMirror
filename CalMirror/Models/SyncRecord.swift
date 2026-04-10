import Foundation
import SwiftData
import SwiftUI

// MARK: - Change Type

/// The type of change that occurred for a specific event during sync.
enum SyncChangeType: String, Codable, Sendable {
    case created
    case updated
    case deleted
    case error

    /// Icon matching EventsOverviewView conventions.
    var iconName: String {
        switch self {
        case .created: "icloud.and.arrow.up"       // pending → blue
        case .updated: "arrow.triangle.2.circlepath.icloud" // modified → purple
        case .deleted: "icloud.and.arrow.down"      // pendingDelete → orange
        case .error:   "xmark.icloud"               // error → red
        }
    }

    /// Color matching EventsOverviewView conventions.
    var color: Color {
        switch self {
        case .created: .blue
        case .updated: .purple
        case .deleted: .orange
        case .error:   .red
        }
    }

    var displayName: String {
        switch self {
        case .created: "Created"
        case .updated: "Updated"
        case .deleted: "Deleted"
        case .error:   "Error"
        }
    }
}

// MARK: - Message Severity

enum SyncMessageSeverity: String, Codable, Sendable {
    case info
    case warning
    case error

    var iconName: String {
        switch self {
        case .info:    "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error:   "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .info:    .secondary
        case .warning: .orange
        case .error:   .red
        }
    }
}

// MARK: - Codable Detail Types

struct SyncRecordEntry: Codable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var changeType: SyncChangeType
    var errorMessage: String?

    init(title: String, changeType: SyncChangeType, errorMessage: String? = nil) {
        self.id = UUID()
        self.title = title
        self.changeType = changeType
        self.errorMessage = errorMessage
    }
}

struct SyncRecordMessage: Codable, Sendable, Identifiable {
    var id: UUID
    var severity: SyncMessageSeverity
    var text: String

    init(severity: SyncMessageSeverity, text: String) {
        self.id = UUID()
        self.severity = severity
        self.text = text
    }
}

// MARK: - Persisted Sync Record

@Model
final class SyncRecord {
    var id: UUID
    var timestamp: Date
    var createdCount: Int
    var updatedCount: Int
    var deletedCount: Int
    var entriesJSON: Data
    var messagesJSON: Data

    init(
        timestamp: Date,
        createdCount: Int,
        updatedCount: Int,
        deletedCount: Int,
        entries: [SyncRecordEntry],
        messages: [SyncRecordMessage]
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.createdCount = createdCount
        self.updatedCount = updatedCount
        self.deletedCount = deletedCount
        self.entriesJSON = (try? JSONEncoder().encode(entries)) ?? Data()
        self.messagesJSON = (try? JSONEncoder().encode(messages)) ?? Data()
    }

    var entries: [SyncRecordEntry] {
        (try? JSONDecoder().decode([SyncRecordEntry].self, from: entriesJSON)) ?? []
    }

    var messages: [SyncRecordMessage] {
        (try? JSONDecoder().decode([SyncRecordMessage].self, from: messagesJSON)) ?? []
    }

    var totalChanges: Int { createdCount + updatedCount + deletedCount }
    var hasErrors: Bool { messages.contains { $0.severity == .error } || entries.contains { $0.changeType == .error } }
    var isSuccess: Bool { !hasErrors }

    var summary: String {
        if totalChanges == 0 && !hasErrors {
            return "No changes"
        }
        var parts: [String] = []
        if createdCount > 0 { parts.append("\(createdCount) created") }
        if updatedCount > 0 { parts.append("\(updatedCount) updated") }
        if deletedCount > 0 { parts.append("\(deletedCount) deleted") }
        let errorCount = messages.count(where: { $0.severity == .error })
        if errorCount > 0 { parts.append("\(errorCount) errors") }
        return parts.joined(separator: ", ")
    }

    /// Creates a SyncRecord from a SyncResult.
    convenience init(from result: SyncResult) {
        self.init(
            timestamp: result.timestamp,
            createdCount: result.created,
            updatedCount: result.updated,
            deletedCount: result.deleted,
            entries: result.detailedEntries,
            messages: result.logMessages
        )
    }

    /// Deletes SyncRecords older than the given number of days.
    static func deleteOlderThan(days: Int, context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<SyncRecord>(
            predicate: #Predicate { $0.timestamp < cutoff }
        )
        guard let old = try? context.fetch(descriptor), !old.isEmpty else { return }
        for record in old {
            context.delete(record)
        }
        try? context.save()
    }
}
