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

    /// Performs a full sync: reads events from EventKit, compares with cache, and pushes changes to CalDAV.
    func performSync(modelContext: ModelContext) async -> SyncResult {
        guard !isSyncing else {
            logger.warning("Sync skipped — already in progress")
            return SyncResult(errors: ["Sync already in progress"])
        }

        logger.info("========== SYNC STARTED ==========")
        isSyncing = true

        var result = SyncResult()

        // 1. Load server configuration
        let serverConfigs: [ServerConfiguration]
        do {
            let descriptor = FetchDescriptor<ServerConfiguration>(
                predicate: #Predicate { $0.isActive }
            )
            serverConfigs = try modelContext.fetch(descriptor)
        } catch {
            result.errors.append("Failed to load server config: \(error.localizedDescription)")
            lastSyncResult = result
            isSyncing = false
            return result
        }

        guard let serverConfig = serverConfigs.first else {
            logger.error("No active server configuration found")
            result.errors.append("No active server configuration found")
            lastSyncResult = result
            isSyncing = false
            return result
        }
        logger.info("Server: \(serverConfig.serverURL), path: \(serverConfig.calendarPath), user: \(serverConfig.username)")

        guard let password = KeychainHelper.load(
            service: serverConfig.keychainServiceID,
            account: serverConfig.username
        ) else {
            logger.error("No password in Keychain for service=\(serverConfig.keychainServiceID), account=\(serverConfig.username)")
            result.errors.append("No password found in Keychain")
            lastSyncResult = result
            isSyncing = false
            return result
        }
        logger.info("Password loaded from Keychain (length=\(password.count))")

        // 2. Load enabled calendars
        let calendarConfigs: [CalendarSyncConfig]
        do {
            let descriptor = FetchDescriptor<CalendarSyncConfig>(
                predicate: #Predicate { $0.isEnabled }
            )
            calendarConfigs = try modelContext.fetch(descriptor)
        } catch {
            result.errors.append("Failed to load calendar configs: \(error.localizedDescription)")
            lastSyncResult = result
            isSyncing = false
            return result
        }

        guard !calendarConfigs.isEmpty else {
            logger.error("No calendars selected for sync")
            result.errors.append("No calendars selected for sync")
            lastSyncResult = result
            isSyncing = false
            return result
        }
        logger.info("Enabled calendars: \(calendarConfigs.count)")

        // 3. Resolve EKCalendar objects
        let selectedCalendars = calendarConfigs.compactMap { config in
            eventStore.calendar(withIdentifier: config.calendarIdentifier)
        }

        guard !selectedCalendars.isEmpty else {
            logger.error("Selected calendars no longer available (IDs: \(calendarConfigs.map { $0.calendarIdentifier }))")
            result.errors.append("Selected calendars no longer available")
            lastSyncResult = result
            isSyncing = false
            return result
        }
        logger.info("Resolved \(selectedCalendars.count) EKCalendars: \(selectedCalendars.map { $0.title })")

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
            logger.info("Calendar '\(ekCalendar.title)': \(events.count) events (\(startDate) → \(endDate))")
            currentEvents.append(contentsOf: events)
        }
        logger.info("Total events from EventKit: \(currentEvents.count)")

        // 6. Load cached events from SwiftData
        let cachedEvents: [CachedEvent]
        do {
            let descriptor = FetchDescriptor<CachedEvent>()
            cachedEvents = try modelContext.fetch(descriptor)
        } catch {
            result.errors.append("Failed to load cache: \(error.localizedDescription)")
            lastSyncResult = result
            isSyncing = false
            return result
        }

        logger.info("Cached events in DB: \(cachedEvents.count)")

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
            logger.error("CalDAV client init failed: \(error.localizedDescription)")
            result.errors.append("CalDAV client error: \(error.localizedDescription)")
            lastSyncResult = result
            isSyncing = false
            return result
        }

        // 8. Build lookup maps
        let cachedByIdentifier = Dictionary(
            uniqueKeysWithValues: cachedEvents.map { ($0.eventIdentifier, $0) }
        )
        let currentIdentifiers = Set(currentEvents.map { $0.eventIdentifier })
        let enabledCalendarIdentifiers = Set(calendarConfigs.map { $0.calendarIdentifier })

        // 9. Prepare all network operations on the main actor (ICS generation etc.),
        //    then execute them off the main actor to keep the UI responsive.
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
                }
            } else {
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
                pendingDeletes.append(PendingDelete(
                    eventIdentifier: cached.eventIdentifier,
                    remoteUID: cached.remoteUID,
                    title: cached.title
                ))
            }
        }

        logger.info("Pending operations: \(pendingPuts.count) PUTs, \(pendingDeletes.count) DELETEs")
        for put in pendingPuts {
            logger.debug("  PUT: '\(put.title)' uid=\(put.remoteUID) new=\(put.isNew)")
        }
        for del in pendingDeletes {
            logger.debug("  DELETE: '\(del.title)' uid=\(del.remoteUID)")
        }

        // 10. Execute all network I/O off the main actor
        let networkResult = await Self.executeNetworkOperations(
            client: client,
            puts: pendingPuts,
            deletes: pendingDeletes
        )

        // 11. Apply results back to SwiftData on the main actor
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
                }
            } else if let error = putResult.error {
                let action = putResult.isNew ? "Create" : "Update"
                result.errors.append("\(action) failed for '\(putResult.title)': \(error)")
            }
        }

        for deleteResult in networkResult.deleteResults {
            if deleteResult.succeeded {
                if let cached = cachedByIdentifier[deleteResult.eventIdentifier] {
                    modelContext.delete(cached)
                    result.deleted += 1
                }
            } else if let error = deleteResult.error {
                result.errors.append("Delete failed for '\(deleteResult.title)': \(error)")
            }
        }

        // 12. Save SwiftData changes
        do {
            try modelContext.save()
        } catch {
            result.errors.append("Failed to save cache: \(error.localizedDescription)")
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

private struct PendingPut: Sendable {
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

private struct PendingDelete: Sendable {
    let eventIdentifier: String
    let remoteUID: String
    let title: String
}

private struct PutResult: Sendable {
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

private struct DeleteResult: Sendable {
    let eventIdentifier: String
    let title: String
    let succeeded: Bool
    let error: String?
}

private struct NetworkSyncResult: Sendable {
    var putResults: [PutResult]
    var deleteResults: [DeleteResult]
}
