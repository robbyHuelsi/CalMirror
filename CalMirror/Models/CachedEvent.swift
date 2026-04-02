import Foundation
import CryptoKit

typealias CachedEvent = SchemaV1.CachedEvent

extension SchemaV1.CachedEvent {
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
