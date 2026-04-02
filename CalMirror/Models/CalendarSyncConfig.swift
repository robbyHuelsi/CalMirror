import Foundation

typealias CalendarSyncConfig = SchemaV1.CalendarSyncConfig

extension SchemaV1.CalendarSyncConfig {
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
