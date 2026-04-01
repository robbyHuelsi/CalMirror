import EventKit
import Foundation
import SwiftData

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
            return SyncResult(errors: ["Sync already in progress"])
        }

        isSyncing = true
        defer { isSyncing = false }

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
            return result
        }

        guard let serverConfig = serverConfigs.first else {
            result.errors.append("No active server configuration found")
            lastSyncResult = result
            return result
        }

        guard let password = KeychainHelper.load(
            service: serverConfig.keychainServiceID,
            account: serverConfig.username
        ) else {
            result.errors.append("No password found in Keychain")
            lastSyncResult = result
            return result
        }

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
            return result
        }

        guard !calendarConfigs.isEmpty else {
            result.errors.append("No calendars selected for sync")
            lastSyncResult = result
            return result
        }

        // 3. Resolve EKCalendar objects
        let selectedCalendars = calendarConfigs.compactMap { config in
            eventStore.calendar(withIdentifier: config.calendarIdentifier)
        }

        guard !selectedCalendars.isEmpty else {
            result.errors.append("Selected calendars no longer available")
            lastSyncResult = result
            return result
        }

        // 4. Build prefix map
        var prefixMap: [String: String?] = [:]
        for config in calendarConfigs {
            prefixMap[config.calendarIdentifier] = config.effectivePrefix
        }

        // 5. Fetch events from EventKit (1 month back, 6 months forward)
        let startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let endDate = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
        let currentEvents = eventStore.fetchEvents(from: startDate, to: endDate, calendars: selectedCalendars)

        // 6. Load cached events from SwiftData
        let cachedEvents: [CachedEvent]
        do {
            let descriptor = FetchDescriptor<CachedEvent>()
            cachedEvents = try modelContext.fetch(descriptor)
        } catch {
            result.errors.append("Failed to load cache: \(error.localizedDescription)")
            lastSyncResult = result
            return result
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
            result.errors.append("CalDAV client error: \(error.localizedDescription)")
            lastSyncResult = result
            return result
        }

        // 8. Build lookup maps
        let cachedByIdentifier = Dictionary(
            uniqueKeysWithValues: cachedEvents.map { ($0.eventIdentifier, $0) }
        )
        let currentIdentifiers = Set(currentEvents.map { $0.eventIdentifier })
        let enabledCalendarIdentifiers = Set(calendarConfigs.map { $0.calendarIdentifier })

        // 9. Process new and changed events
        for event in currentEvents {
            let prefix = prefixMap[event.calendar.calendarIdentifier] ?? nil

            if let cached = cachedByIdentifier[event.eventIdentifier] {
                // Event exists in cache — check for changes
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
                    // Event changed — update on server
                    let ics = ICSGenerator.generateICS(from: event, uid: cached.remoteUID, prefix: prefix)
                    do {
                        try await client.putEvent(icsData: ics, uid: cached.remoteUID)
                        cached.title = event.title ?? ""
                        cached.startDate = event.startDate
                        cached.endDate = event.endDate
                        cached.location = event.location
                        cached.notes = event.notes
                        cached.isAllDay = event.isAllDay
                        cached.lastModified = Date()
                        cached.recurrenceRuleDescription = event.recurrenceRules?.first?.description
                        cached.contentHash = newHash
                        cached.lastSyncedAt = Date()
                        result.updated += 1
                    } catch {
                        result.errors.append("Update failed for '\(event.title ?? "")': \(error.localizedDescription)")
                    }
                }
            } else {
                // New event — create on server
                let remoteUID = UUID().uuidString
                let ics = ICSGenerator.generateICS(from: event, uid: remoteUID, prefix: prefix)
                do {
                    try await client.putEvent(icsData: ics, uid: remoteUID)
                    let cached = CachedEvent(
                        eventIdentifier: event.eventIdentifier,
                        calendarIdentifier: event.calendar.calendarIdentifier,
                        title: event.title ?? "",
                        startDate: event.startDate,
                        endDate: event.endDate,
                        location: event.location,
                        notes: event.notes,
                        isAllDay: event.isAllDay,
                        lastModified: Date(),
                        recurrenceRuleDescription: event.recurrenceRules?.first?.description,
                        remoteUID: remoteUID
                    )
                    modelContext.insert(cached)
                    result.created += 1
                } catch {
                    result.errors.append("Create failed for '\(event.title ?? "")': \(error.localizedDescription)")
                }
            }
        }

        // 10. Process deleted events
        for cached in cachedEvents {
            let stillEnabled = enabledCalendarIdentifiers.contains(cached.calendarIdentifier)
            let stillExists = currentIdentifiers.contains(cached.eventIdentifier)

            if !stillExists || !stillEnabled {
                do {
                    try await client.deleteEvent(uid: cached.remoteUID)
                    modelContext.delete(cached)
                    result.deleted += 1
                } catch {
                    result.errors.append("Delete failed for '\(cached.title)': \(error.localizedDescription)")
                }
            }
        }

        // 11. Save SwiftData changes
        do {
            try modelContext.save()
        } catch {
            result.errors.append("Failed to save cache: \(error.localizedDescription)")
        }

        lastSyncResult = result
        return result
    }
}
