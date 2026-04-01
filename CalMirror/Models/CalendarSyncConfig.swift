import Foundation
import SwiftData

@Model
final class CalendarSyncConfig {
    @Attribute(.unique) var calendarIdentifier: String
    var calendarName: String
    var isEnabled: Bool
    var isPrefixEnabled: Bool
    var customPrefix: String?

    init(
        calendarIdentifier: String,
        calendarName: String,
        isEnabled: Bool = false,
        isPrefixEnabled: Bool = false,
        customPrefix: String? = nil
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.calendarName = calendarName
        self.isEnabled = isEnabled
        self.isPrefixEnabled = isPrefixEnabled
        self.customPrefix = customPrefix
    }

    /// Returns the effective prefix string to prepend to event titles.
    /// Returns nil if prefix is disabled.
    var effectivePrefix: String? {
        guard isPrefixEnabled else { return nil }
        let prefix = customPrefix?.trimmingCharacters(in: .whitespaces)
        if let prefix, !prefix.isEmpty {
            return prefix
        }
        return calendarName
    }
}
