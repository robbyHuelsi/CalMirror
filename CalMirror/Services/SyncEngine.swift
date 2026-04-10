import EventKit
import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "de.huelsi.CalMirror", category: "Sync")

/// Result of a sync operation.
struct SyncResult: Sendable {
    var created: Int = 0
    var updated: Int = 0
    var deleted: Int = 0
    var errors: [String] = []
    var timestamp: Date = Date()
    var detailedEntries: [SyncRecordEntry] = []
    var logMessages: [SyncLogMessage] = []

    var totalChanges: Int { created + updated + deleted }

    var summary: String {
        if totalChanges == 0 && errors.isEmpty {
            return "No changes"
        }
        var parts: [String] = []
        if created > 0 { parts.append("\(created) created") }
        if updated > 0 { parts.append("\(updated) updated") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if !errors.isEmpty { parts.append("\(errors.count) errors") }
        return parts.joined(separator: ", ")
    }

    mutating func log(_ severity: SyncMessageSeverity, _ text: String) {
        logMessages.append(SyncLogMessage(severity: severity, text: text))
    }

    /// Convenience: add a SyncRecordMessage (alias for log messages stored in SyncResult).
    typealias SyncLogMessage = SyncRecordMessage
}

/// Orchestrates the sync process between EventKit and a CalDAV server.
@MainActor
@Observable
final class SyncEngine {
    private let eventStore: EventReading
    var lastSyncResult: SyncResult?
    var isSyncing = false

    init(eventStore: EventReading) {
        self.eventStore = eventStore
    }

    // MARK: - Sync Plan Analysis

    /// Holds the intermediate state needed to execute a sync after analysis.
    struct AnalysisContext {
        let plan: SyncPlan
        let client: CalDAVClient
        let pendingPuts: [PendingPut]
        let pendingDeletes: [PendingDelete]
        let cachedByIdentifier: [String: CachedEvent]
    }

    /// Analyzes the current sync state without performing any network PUT/DELETE operations.
    /// Used by EventsOverviewView to display per-event sync status.
    func analyzeSyncPlan(modelContext: ModelContext) async -> SyncPlan {
        let (plan, _) = await analyzeInternal(modelContext: modelContext)
        return plan
    }

    /// Internal analysis that returns both the plan (for display) and the context (for execution).
    private func analyzeInternal(modelContext: ModelContext) async -> (SyncPlan, AnalysisContext?) {
        var errors: [String] = []

        // 1. Load server configuration
        let serverConfigs: [ServerConfiguration]
        do {
            let descriptor = FetchDescriptor<ServerConfiguration>(
                predicate: #Predicate { $0.isActive }
            )
            serverConfigs = try modelContext.fetch(descriptor)
        } catch {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["Failed to load server config: \(error.localizedDescription)"]), nil)
        }

        guard let serverConfig = serverConfigs.first else {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["No active server configuration found"]), nil)
        }

        let password = KeychainHelper.load(
            service: serverConfig.keychainServiceID,
            account: serverConfig.username
        )
        guard let password else {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["No password found in Keychain"]), nil)
        }

        // 2. Load enabled calendars
        let calendarConfigs: [CalendarSyncConfig]
        do {
            let descriptor = FetchDescriptor<CalendarSyncConfig>(
                predicate: #Predicate { $0.isEnabled }
            )
            calendarConfigs = try modelContext.fetch(descriptor)
        } catch {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["Failed to load calendar configs: \(error.localizedDescription)"]), nil)
        }

        guard !calendarConfigs.isEmpty else {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["No calendars selected for sync"]), nil)
        }

        // 3. Resolve EKCalendar objects
        let selectedCalendars = calendarConfigs.compactMap { config in
            eventStore.calendar(withIdentifier: config.calendarIdentifier)
        }

        guard !selectedCalendars.isEmpty else {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["Selected calendars no longer available"]), nil)
        }

        // 4. Build config lookup
        var configMap: [String: CalendarSyncConfig] = [:]
        for config in calendarConfigs {
            configMap[config.calendarIdentifier] = config
        }

        // 5. Fetch events from EventKit per calendar using configured time windows
        let now = Date()
        let cal = Calendar.current
        var currentEvents: [EKEvent] = []

        for ekCalendar in selectedCalendars {
            let config = configMap[ekCalendar.calendarIdentifier]
            let past = config?.pastComponent ?? (.weekOfYear, 1)
            let future = config?.futureComponent ?? (.year, 1)

            let startDate = cal.date(byAdding: past.component, value: -past.value, to: now) ?? now
            let endDate = cal.date(byAdding: future.component, value: future.value, to: now) ?? now

            let events = eventStore.fetchEvents(from: startDate, to: endDate, calendars: [ekCalendar])
            currentEvents.append(contentsOf: events)
        }

        // 6. Load cached events from SwiftData
        let cachedEvents: [CachedEvent]
        do {
            let descriptor = FetchDescriptor<CachedEvent>()
            cachedEvents = try modelContext.fetch(descriptor)
        } catch {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["Failed to load cache: \(error.localizedDescription)"]), nil)
        }

        // 7. Create CalDAV client
        let client: CalDAVClient
        do {
            client = try CalDAVClient(
                serverURL: serverConfig.serverURL,
                calendarPath: serverConfig.calendarPath,
                username: serverConfig.username,
                password: password
            )
        } catch {
            return (SyncPlan(entries: [], remoteUIDsAvailable: false, errors: ["CalDAV client error: \(error.localizedDescription)"]), nil)
        }

        // 8. Fetch remote event metadata for orphan detection (graceful degradation)
        var remoteMetadata: [RemoteEventMetadata]?
        do {
            remoteMetadata = try await client.fetchRemoteEventMetadata()
        } catch {
            logger.warning("Could not fetch remote event metadata, falling back to UIDs: \(error.localizedDescription)")
            // Fallback: try listEventUIDs for servers that don't support REPORT
            do {
                let uids = try await client.listEventUIDs()
                remoteMetadata = uids.map { RemoteEventMetadata(uid: $0, title: $0, startDate: .distantPast, endDate: .distantPast, isAllDay: false) }
            } catch {
                logger.warning("Could not list remote UIDs either: \(error.localizedDescription)")
                errors.append("Could not list server events: \(error.localizedDescription)")
            }
        }

        // 9. Build lookup maps
        let cachedByIdentifier = Dictionary(
            uniqueKeysWithValues: cachedEvents.map { ($0.eventIdentifier, $0) }
        )
        let currentIdentifiers = Set(currentEvents.map { $0.eventIdentifier })
        let enabledCalendarIdentifiers = Set(calendarConfigs.map { $0.calendarIdentifier })
        let cachedRemoteUIDs = Set(cachedEvents.map { $0.remoteUID })

        // 10. Classify events and build plan entries + pending operations
        var entries: [SyncPlanEntry] = []
        var pendingPuts: [PendingPut] = []
        var pendingDeletes: [PendingDelete] = []

        for event in currentEvents {
            let prefix = configMap[event.calendar.calendarIdentifier]?.effectivePrefix

            if let cached = cachedByIdentifier[event.eventIdentifier] {
                let newHash = CachedEvent.computeHash(
                    title: event.title ?? "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    isAllDay: event.isAllDay,
                    recurrenceRuleDescription: event.recurrenceRules?.first?.description
                )

                if newHash != cached.contentHash {
                    // Modified — cached but content changed
                    entries.append(SyncPlanEntry(
                        id: event.eventIdentifier,
                        title: event.title ?? "",
                        startDate: event.startDate,
                        endDate: event.endDate,
                        isAllDay: event.isAllDay,
                        calendarIdentifier: event.calendar.calendarIdentifier,
                        remoteUID: cached.remoteUID,
                        status: .modified,
                        prefix: prefix
                    ))
                    let ics = ICSGenerator.generateICS(from: event, uid: cached.remoteUID, prefix: prefix)
                    pendingPuts.append(PendingPut(
                        eventIdentifier: event.eventIdentifier,
                        calendarIdentifier: event.calendar.calendarIdentifier,
                        title: event.title ?? "",
                        startDate: event.startDate,
                        endDate: event.endDate,
                        location: event.location,
                        notes: event.notes,
                        isAllDay: event.isAllDay,
                        recurrenceRuleDescription: event.recurrenceRules?.first?.description,
                        contentHash: newHash,
                        remoteUID: cached.remoteUID,
                        icsData: ics,
                        isNew: false
                    ))
                } else {
                    // Synced — cached and hash matches
                    entries.append(SyncPlanEntry(
                        id: event.eventIdentifier,
                        title: event.title ?? "",
                        startDate: event.startDate,
                        endDate: event.endDate,
                        isAllDay: event.isAllDay,
                        calendarIdentifier: event.calendar.calendarIdentifier,
                        remoteUID: cached.remoteUID,
                        status: .synced,
                        prefix: prefix
                    ))
                }
            } else {
                // Pending — not yet in cache
                let remoteUID = UUID().uuidString
                let ics = ICSGenerator.generateICS(from: event, uid: remoteUID, prefix: prefix)
                let newEventHash = CachedEvent.computeHash(
                    title: event.title ?? "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    isAllDay: event.isAllDay,
                    recurrenceRuleDescription: event.recurrenceRules?.first?.description
                )

                entries.append(SyncPlanEntry(
                    id: event.eventIdentifier,
                    title: event.title ?? "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarIdentifier: event.calendar.calendarIdentifier,
                    remoteUID: remoteUID,
                    status: .pending,
                    prefix: prefix
                ))
                pendingPuts.append(PendingPut(
                    eventIdentifier: event.eventIdentifier,
                    calendarIdentifier: event.calendar.calendarIdentifier,
                    title: event.title ?? "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    isAllDay: event.isAllDay,
                    recurrenceRuleDescription: event.recurrenceRules?.first?.description,
                    contentHash: newEventHash,
                    remoteUID: remoteUID,
                    icsData: ics,
                    isNew: true
                ))
            }
        }

        // Detect pending deletes
        for cached in cachedEvents {
            let stillEnabled = enabledCalendarIdentifiers.contains(cached.calendarIdentifier)
            let stillExists = currentIdentifiers.contains(cached.eventIdentifier)

            var outsideTimeWindow = false
            if stillEnabled, let config = configMap[cached.calendarIdentifier] {
                let past = config.pastComponent
                let future = config.futureComponent
                let pastCutoff = cal.date(byAdding: past.component, value: -past.value, to: now) ?? now
                let futureCutoff = cal.date(byAdding: future.component, value: future.value, to: now) ?? now
                if cached.endDate < pastCutoff || cached.startDate > futureCutoff {
                    outsideTimeWindow = true
                }
            }

            if !stillExists || !stillEnabled || outsideTimeWindow {
                entries.append(SyncPlanEntry(
                    id: "delete-\(cached.eventIdentifier)",
                    title: cached.title,
                    startDate: cached.startDate,
                    endDate: cached.endDate,
                    isAllDay: cached.isAllDay,
                    calendarIdentifier: cached.calendarIdentifier,
                    remoteUID: cached.remoteUID,
                    status: .pendingDelete,
                    prefix: configMap[cached.calendarIdentifier]?.effectivePrefix
                ))
                pendingDeletes.append(PendingDelete(
                    eventIdentifier: cached.eventIdentifier,
                    remoteUID: cached.remoteUID,
                    title: cached.title
                ))
            }
        }

        // Detect orphaned events (on server but not tracked locally)
        if let remoteMetadata {
            let remoteUIDs = Set(remoteMetadata.map { $0.uid })
            let orphanedUIDs = remoteUIDs.subtracting(cachedRemoteUIDs)
            let metaByUID = Dictionary(remoteMetadata.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            for uid in orphanedUIDs {
                let meta = metaByUID[uid]
                entries.append(SyncPlanEntry(
                    id: "orphan-\(uid)",
                    title: meta?.title ?? uid,
                    startDate: meta?.startDate ?? .distantPast,
                    endDate: meta?.endDate ?? .distantPast,
                    isAllDay: meta?.isAllDay ?? false,
                    calendarIdentifier: nil,
                    remoteUID: uid,
                    status: .orphaned,
                    prefix: nil
                ))
            }
        }

        let plan = SyncPlan(
            entries: entries,
            remoteUIDsAvailable: remoteMetadata != nil,
            errors: errors
        )

        let context = AnalysisContext(
            plan: plan,
            client: client,
            pendingPuts: pendingPuts,
            pendingDeletes: pendingDeletes,
            cachedByIdentifier: cachedByIdentifier
        )

        return (plan, context)
    }

    // MARK: - Full Sync

    /// Performs a full sync: reads events from EventKit, compares with cache, and pushes changes to CalDAV.
    func performSync(modelContext: ModelContext) async -> SyncResult {
        guard !isSyncing else {
            logger.warning("Sync skipped — already in progress")
            return SyncResult(errors: ["Sync already in progress"])
        }

        logger.info("========== SYNC STARTED ==========")
        isSyncing = true

        let (plan, analysisContext) = await analyzeInternal(modelContext: modelContext)

        guard let ctx = analysisContext else {
            var result = SyncResult(errors: plan.errors)
            for error in plan.errors {
                result.log(.error, error)
            }
            lastSyncResult = result
            isSyncing = false
            return result
        }

        var result = SyncResult()

        let pendingPuts = ctx.pendingPuts
        let pendingDeletes = ctx.pendingDeletes
        let cachedByIdentifier = ctx.cachedByIdentifier

        result.log(.info, "Starting sync: \(pendingPuts.count) PUTs, \(pendingDeletes.count) DELETEs")
        logger.info("Pending operations: \(pendingPuts.count) PUTs, \(pendingDeletes.count) DELETEs")
        for put in pendingPuts {
            logger.debug("  PUT: '\(put.title)' uid=\(put.remoteUID) new=\(put.isNew)")
        }
        for del in pendingDeletes {
            logger.debug("  DELETE: '\(del.title)' uid=\(del.remoteUID)")
        }

        // Execute all network I/O off the main actor
        let networkResult = await Self.executeNetworkOperations(
            client: ctx.client,
            puts: pendingPuts,
            deletes: pendingDeletes
        )

        // Apply results back to SwiftData on the main actor
        for putResult in networkResult.putResults {
            if putResult.succeeded {
                if putResult.isNew {
                    let cached = CachedEvent(
                        eventIdentifier: putResult.eventIdentifier,
                        calendarIdentifier: putResult.calendarIdentifier,
                        title: putResult.title,
                        startDate: putResult.startDate,
                        endDate: putResult.endDate,
                        location: putResult.location,
                        notes: putResult.notes,
                        isAllDay: putResult.isAllDay,
                        lastModified: Date(),
                        recurrenceRuleDescription: putResult.recurrenceRuleDescription,
                        remoteUID: putResult.remoteUID
                    )
                    cached.contentHash = putResult.contentHash ?? CachedEvent.computeHash(
                        title: putResult.title,
                        startDate: putResult.startDate,
                        endDate: putResult.endDate,
                        location: putResult.location,
                        notes: putResult.notes,
                        isAllDay: putResult.isAllDay,
                        recurrenceRuleDescription: putResult.recurrenceRuleDescription
                    )
                    modelContext.insert(cached)
                    result.created += 1
                    result.detailedEntries.append(SyncRecordEntry(title: putResult.title, changeType: .created))
                } else if let cached = cachedByIdentifier[putResult.eventIdentifier] {
                    cached.title = putResult.title
                    cached.startDate = putResult.startDate
                    cached.endDate = putResult.endDate
                    cached.location = putResult.location
                    cached.notes = putResult.notes
                    cached.isAllDay = putResult.isAllDay
                    cached.lastModified = Date()
                    cached.recurrenceRuleDescription = putResult.recurrenceRuleDescription
                    cached.contentHash = putResult.contentHash ?? cached.contentHash
                    cached.lastSyncedAt = Date()
                    result.updated += 1
                    result.detailedEntries.append(SyncRecordEntry(title: putResult.title, changeType: .updated))
                }
            } else if let error = putResult.error {
                let action = putResult.isNew ? "Create" : "Update"
                result.errors.append("\(action) failed for '\(putResult.title)': \(error)")
                result.detailedEntries.append(SyncRecordEntry(title: putResult.title, changeType: .error, errorMessage: error))
                result.log(.error, "\(action) failed for '\(putResult.title)': \(error)")
            }
        }

        for deleteResult in networkResult.deleteResults {
            if deleteResult.succeeded {
                if let cached = cachedByIdentifier[deleteResult.eventIdentifier] {
                    modelContext.delete(cached)
                    result.deleted += 1
                    result.detailedEntries.append(SyncRecordEntry(title: deleteResult.title, changeType: .deleted))
                }
            } else if let error = deleteResult.error {
                result.errors.append("Delete failed for '\(deleteResult.title)': \(error)")
                result.detailedEntries.append(SyncRecordEntry(title: deleteResult.title, changeType: .error, errorMessage: error))
                result.log(.error, "Delete failed for '\(deleteResult.title)': \(error)")
            }
        }

        // Save SwiftData changes
        do {
            try modelContext.save()
        } catch {
            result.errors.append("Failed to save cache: \(error.localizedDescription)")
            result.log(.error, "Failed to save cache: \(error.localizedDescription)")
        }

        if result.totalChanges == 0 && result.errors.isEmpty {
            result.log(.info, "No changes detected")
        } else {
            result.log(.info, "Sync finished: \(result.summary)")
        }

        logger.info("========== SYNC FINISHED: \(result.summary) ==========")
        if !result.errors.isEmpty {
            for err in result.errors {
                logger.error("  Sync error: \(err)")
            }
        }

        lastSyncResult = result
        isSyncing = false
        return result
    }

    /// Executes all network PUT and DELETE operations off the main actor.
    nonisolated private static func executeNetworkOperations(
        client: CalDAVClient,
        puts: [PendingPut],
        deletes: [PendingDelete]
    ) async -> NetworkSyncResult {
        var result = NetworkSyncResult(putResults: [], deleteResults: [])

        for put in puts {
            do {
                try await client.putEvent(icsData: put.icsData, uid: put.remoteUID, isNew: put.isNew)
                result.putResults.append(PutResult(
                    eventIdentifier: put.eventIdentifier,
                    calendarIdentifier: put.calendarIdentifier,
                    title: put.title,
                    startDate: put.startDate,
                    endDate: put.endDate,
                    location: put.location,
                    notes: put.notes,
                    isAllDay: put.isAllDay,
                    recurrenceRuleDescription: put.recurrenceRuleDescription,
                    contentHash: put.contentHash,
                    remoteUID: put.remoteUID,
                    isNew: put.isNew,
                    succeeded: true,
                    error: nil
                ))
            } catch {
                result.putResults.append(PutResult(
                    eventIdentifier: put.eventIdentifier,
                    calendarIdentifier: put.calendarIdentifier,
                    title: put.title,
                    startDate: put.startDate,
                    endDate: put.endDate,
                    location: put.location,
                    notes: put.notes,
                    isAllDay: put.isAllDay,
                    recurrenceRuleDescription: put.recurrenceRuleDescription,
                    contentHash: put.contentHash,
                    remoteUID: put.remoteUID,
                    isNew: put.isNew,
                    succeeded: false,
                    error: error.localizedDescription
                ))
            }
        }

        for delete in deletes {
            do {
                try await client.deleteEvent(uid: delete.remoteUID)
                result.deleteResults.append(DeleteResult(
                    eventIdentifier: delete.eventIdentifier,
                    title: delete.title,
                    succeeded: true,
                    error: nil
                ))
            } catch {
                result.deleteResults.append(DeleteResult(
                    eventIdentifier: delete.eventIdentifier,
                    title: delete.title,
                    succeeded: false,
                    error: error.localizedDescription
                ))
            }
        }

        return result
    }
}

// MARK: - Sendable value types for off-main-actor network operations

struct PendingPut: Sendable {
    let eventIdentifier: String
    let calendarIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let isAllDay: Bool
    let recurrenceRuleDescription: String?
    let contentHash: String?
    let remoteUID: String
    let icsData: String
    let isNew: Bool
}

struct PendingDelete: Sendable {
    let eventIdentifier: String
    let remoteUID: String
    let title: String
}

struct PutResult: Sendable {
    let eventIdentifier: String
    let calendarIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let isAllDay: Bool
    let recurrenceRuleDescription: String?
    let contentHash: String?
    let remoteUID: String
    let isNew: Bool
    let succeeded: Bool
    let error: String?
}

struct DeleteResult: Sendable {
    let eventIdentifier: String
    let title: String
    let succeeded: Bool
    let error: String?
}

struct NetworkSyncResult: Sendable {
    var putResults: [PutResult]
    var deleteResults: [DeleteResult]
}
