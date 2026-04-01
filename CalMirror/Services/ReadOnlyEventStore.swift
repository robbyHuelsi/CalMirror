import EventKit
import Foundation

/// Protocol defining read-only access to calendar events.
/// This ensures the app never writes to the user's calendars.
protocol EventReading: Sendable {
    func requestAccess() async throws -> Bool
    func authorizationStatus() -> EKAuthorizationStatus
    func availableCalendars() -> [EKCalendar]
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]?) -> [EKEvent]
    func calendar(withIdentifier identifier: String) -> EKCalendar?
    var changeNotifications: AsyncStream<Void> { get }
}

/// A read-only wrapper around EKEventStore.
/// The underlying EKEventStore is private and never exposed,
/// guaranteeing that no write operations can be performed on the calendar database.
final class ReadOnlyEventStore: EventReading, @unchecked Sendable {
    private let store = EKEventStore()
    private let lock = NSLock()

    var changeNotifications: AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: self.store,
                queue: nil
            ) { _ in
                continuation.yield()
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return true
        case .notDetermined:
            return try await store.requestFullAccessToEvents()
        case .denied, .restricted:
            return false
        case .writeOnly:
            // Write-only doesn't allow reading — we need full access
            return false
        @unknown default:
            return false
        }
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func availableCalendars() -> [EKCalendar] {
        lock.lock()
        defer { lock.unlock() }
        return store.calendars(for: .event)
    }

    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]?) -> [EKEvent] {
        lock.lock()
        defer { lock.unlock() }
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return store.events(matching: predicate)
    }

    func calendar(withIdentifier identifier: String) -> EKCalendar? {
        lock.lock()
        defer { lock.unlock() }
        return store.calendar(withIdentifier: identifier)
    }
}
