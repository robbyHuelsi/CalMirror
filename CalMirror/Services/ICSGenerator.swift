import EventKit
import Foundation

/// Generates RFC 5545 iCalendar (.ics) data from EventKit events.
enum ICSGenerator {

    /// Generates a complete VCALENDAR string for a single event.
    static func generateICS(
        from event: EKEvent,
        uid: String,
        prefix: String?
    ) -> String {
        var lines: [String] = []
        lines.append("BEGIN:VCALENDAR")
        lines.append("VERSION:2.0")
        lines.append("PRODID:-//CalMirror//CalMirror//EN")
        lines.append("CALSCALE:GREGORIAN")
        lines.append("METHOD:PUBLISH")

        lines.append("BEGIN:VEVENT")
        lines.append("UID:\(uid)")
        lines.append("DTSTAMP:\(formatDateUTC(Date()))")

        if event.isAllDay {
            lines.append("DTSTART;VALUE=DATE:\(formatDateOnly(event.startDate))")
            lines.append("DTEND;VALUE=DATE:\(formatDateOnly(event.endDate))")
        } else {
            lines.append("DTSTART:\(formatDateUTC(event.startDate))")
            lines.append("DTEND:\(formatDateUTC(event.endDate))")
        }

        let title = prefixedTitle(event.title ?? "", prefix: prefix)
        lines.append("SUMMARY:\(escapeICSText(title))")

        if let location = event.location, !location.isEmpty {
            lines.append("LOCATION:\(escapeICSText(location))")
        }

        if let notes = event.notes, !notes.isEmpty {
            lines.append("DESCRIPTION:\(escapeICSText(notes))")
        }

        if let url = event.url {
            lines.append("URL:\(url.absoluteString)")
        }

        switch event.availability {
        case .busy:
            lines.append("TRANSP:OPAQUE")
        case .free:
            lines.append("TRANSP:TRANSPARENT")
        case .tentative:
            lines.append("TRANSP:OPAQUE")
            lines.append("STATUS:TENTATIVE")
        default:
            break
        }

        if let recurrenceRules = event.recurrenceRules {
            for rule in recurrenceRules {
                if let rrule = generateRRule(from: rule) {
                    lines.append(rrule)
                }
            }
        }

        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Private Helpers

    private static func prefixedTitle(_ title: String, prefix: String?) -> String {
        guard let prefix, !prefix.isEmpty else { return title }
        return "[\(prefix)] \(title)"
    }

    private static func formatDateUTC(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func formatDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Escapes special characters in iCalendar text values per RFC 5545.
    private static func escapeICSText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Generates an RRULE string from an EKRecurrenceRule.
    private static func generateRRule(from rule: EKRecurrenceRule) -> String? {
        var parts: [String] = []

        switch rule.frequency {
        case .daily:
            parts.append("FREQ=DAILY")
        case .weekly:
            parts.append("FREQ=WEEKLY")
        case .monthly:
            parts.append("FREQ=MONTHLY")
        case .yearly:
            parts.append("FREQ=YEARLY")
        @unknown default:
            return nil
        }

        if rule.interval > 1 {
            parts.append("INTERVAL=\(rule.interval)")
        }

        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate {
                parts.append("UNTIL=\(formatDateUTC(endDate))")
            } else if end.occurrenceCount > 0 {
                parts.append("COUNT=\(end.occurrenceCount)")
            }
        }

        if let daysOfWeek = rule.daysOfTheWeek {
            let dayStrings = daysOfWeek.compactMap { dayOfWeek -> String? in
                let abbrev: String
                switch dayOfWeek.dayOfTheWeek {
                case .sunday: abbrev = "SU"
                case .monday: abbrev = "MO"
                case .tuesday: abbrev = "TU"
                case .wednesday: abbrev = "WE"
                case .thursday: abbrev = "TH"
                case .friday: abbrev = "FR"
                case .saturday: abbrev = "SA"
                @unknown default: return nil
                }
                if dayOfWeek.weekNumber != 0 {
                    return "\(dayOfWeek.weekNumber)\(abbrev)"
                }
                return abbrev
            }
            if !dayStrings.isEmpty {
                parts.append("BYDAY=\(dayStrings.joined(separator: ","))")
            }
        }

        guard !parts.isEmpty else { return nil }
        return "RRULE:\(parts.joined(separator: ";"))"
    }
}
