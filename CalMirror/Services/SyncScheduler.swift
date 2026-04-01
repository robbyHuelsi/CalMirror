import Foundation
import SwiftData

/// Manages sync scheduling: event-based notifications, periodic timer, and manual triggers.
@MainActor
@Observable
final class SyncScheduler {
    let syncEngine: SyncEngine
    private let eventStore: EventReading
    private var notificationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    var isActive = false
    var lastSyncDate: Date?
    var nextScheduledSync: Date?

    private var syncIntervalMinutes: Int = 30
    private var debounceSeconds: TimeInterval = 5

    init(eventStore: EventReading, syncEngine: SyncEngine) {
        self.eventStore = eventStore
        self.syncEngine = syncEngine
    }

    /// Starts the scheduler with event-based and periodic sync.
    func start(intervalMinutes: Int = 30) {
        syncIntervalMinutes = intervalMinutes
        isActive = true
        startEventNotificationListener()
        startPeriodicTimer()
    }

    /// Stops all scheduled sync operations.
    func stop() {
        isActive = false
        notificationTask?.cancel()
        notificationTask = nil
        timerTask?.cancel()
        timerTask = nil
        nextScheduledSync = nil
    }

    /// Updates the sync interval and restarts the periodic timer.
    func updateInterval(minutes: Int) {
        syncIntervalMinutes = minutes
        timerTask?.cancel()
        startPeriodicTimer()
    }

    /// Manually triggers a sync.
    func triggerSync(modelContext: ModelContext) async -> SyncResult {
        let result = await syncEngine.performSync(modelContext: modelContext)
        lastSyncDate = Date()
        return result
    }

    // MARK: - Private

    private func startEventNotificationListener() {
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            guard let self else { return }
            var lastNotification = Date.distantPast

            for await _ in self.eventStore.changeNotifications {
                guard !Task.isCancelled else { break }

                // Debounce: ignore notifications within 5 seconds of each other
                let now = Date()
                if now.timeIntervalSince(lastNotification) < self.debounceSeconds {
                    continue
                }
                lastNotification = now

                // Post a notification so the UI can trigger the sync with its ModelContext.
                NotificationCenter.default.post(
                    name: .calendarDidChange,
                    object: nil
                )
            }
        }
    }

    private func startPeriodicTimer() {
        timerTask?.cancel()
        let interval = TimeInterval(syncIntervalMinutes * 60)
        nextScheduledSync = Date().addingTimeInterval(interval)

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                self?.nextScheduledSync = Date().addingTimeInterval(interval)

                NotificationCenter.default.post(
                    name: .scheduledSyncDidFire,
                    object: nil
                )
            }
        }
    }


}

extension Notification.Name {
    static let calendarDidChange = Notification.Name("CalMirror.calendarDidChange")
    static let scheduledSyncDidFire = Notification.Name("CalMirror.scheduledSyncDidFire")
}
