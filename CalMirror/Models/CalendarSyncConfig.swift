import Foundation
import SwiftData

@Model
final class CalendarSyncConfig {
    @Attribute(.unique) var calendarIdentifier: String
    var calendarName: String
    var isEnabled: Bool
    var isPrefixEnabled: Bool
    var customPrefix: String?
    var pastValue: Int
    var pastUnit: String
    var futureValue: Int
    var futureUnit: String

    init(
        calendarIdentifier: String,
        calendarName: String,
        isEnabled: Bool = false,
        isPrefixEnabled: Bool = false,
        customPrefix: String? = nil,
        pastValue: Int = 1,
        pastUnit: String = "weekOfYear",
        futureValue: Int = 1,
        futureUnit: String = "year"
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.calendarName = calendarName
        self.isEnabled = isEnabled
        self.isPrefixEnabled = isPrefixEnabled
        self.customPrefix = customPrefix
        self.pastValue = pastValue
        self.pastUnit = pastUnit
        self.futureValue = futureValue
        self.futureUnit = futureUnit
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

    /// Returns the past limit as a Calendar.Component and value.
    var pastComponent: (component: Calendar.Component, value: Int) {
        (TimeRangeUnit.component(from: pastUnit), pastValue)
    }

    /// Returns the future limit as a Calendar.Component and value.
    var futureComponent: (component: Calendar.Component, value: Int) {
        (TimeRangeUnit.component(from: futureUnit), futureValue)
    }
}

/// Maps between stored String keys and Calendar.Component.
enum TimeRangeUnit {
    static func component(from raw: String) -> Calendar.Component {
        switch raw {
        case "day": return .day
        case "weekOfYear": return .weekOfYear
        case "month": return .month
        case "year": return .year
        default: return .day
        }
    }
}
