import Foundation
import SwiftData
import CryptoKit

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

    static func computeHash(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        isAllDay: Bool,
        recurrenceRuleDescription: String?
    ) -> String {
        let input = [
            title,
            "\(startDate.timeIntervalSince1970)",
            "\(endDate.timeIntervalSince1970)",
            location ?? "",
            notes ?? "",
            "\(isAllDay)",
            recurrenceRuleDescription ?? ""
        ].joined(separator: "|")

        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
