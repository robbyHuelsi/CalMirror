import Foundation

/// The sync status of an individual event.
enum EventSyncStatus: Sendable {
    /// In EventKit + CachedEvent + on server, content hash matches.
    case synced
    /// In EventKit + CachedEvent, but content hash differs (will be updated on next sync).
    case modified
    /// In EventKit, but not yet in CachedEvent (never synced).
    case pending
    /// In CachedEvent but no longer in EventKit (will be deleted from server on next sync).
    case pendingDelete
    /// On server (by UID), but no CachedEvent locally — unknown to the app.
    case orphaned

    var iconName: String {
        switch self {
        case .synced: "checkmark.icloud"
        case .modified: "arrow.triangle.2.circlepath.icloud"
        case .pending: "icloud.and.arrow.up"
        case .pendingDelete: "icloud.and.arrow.down"
        case .orphaned: "exclamationmark.icloud"
        }
    }

    var iconColor: String {
        switch self {
        case .synced: "green"
        case .modified: "purple"
        case .pending: "blue"
        case .pendingDelete: "orange"
        case .orphaned: "red"
        }
    }

    var displayName: String {
        switch self {
        case .synced: "Synced"
        case .modified: "Modified"
        case .pending: "Pending"
        case .pendingDelete: "Delete"
        case .orphaned: "Orphaned"
        }
    }
}

/// A unified representation of an event in the sync plan, regardless of its source.
struct SyncPlanEntry: Sendable, Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarIdentifier: String?
    let remoteUID: String?
    let status: EventSyncStatus
    let prefix: String?
}

/// The result of analyzing the sync state without executing any network operations.
struct SyncPlan: Sendable {
    let entries: [SyncPlanEntry]
    let remoteUIDsAvailable: Bool
    let errors: [String]

    var syncedCount: Int { entries.count(where: { $0.status == .synced }) }
    var modifiedCount: Int { entries.count(where: { $0.status == .modified }) }
    var pendingCount: Int { entries.count(where: { $0.status == .pending }) }
    var pendingDeleteCount: Int { entries.count(where: { $0.status == .pendingDelete }) }
    var orphanedCount: Int { entries.count(where: { $0.status == .orphaned }) }
}
