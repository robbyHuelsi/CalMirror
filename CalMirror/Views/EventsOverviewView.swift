import SwiftUI
import SwiftData

struct EventsOverviewView: View {
    @Query(sort: \CachedEvent.startDate) private var cachedEvents: [CachedEvent]
    @Query private var calendarConfigs: [CalendarSyncConfig]

    private var configMap: [String: CalendarSyncConfig] {
        Dictionary(uniqueKeysWithValues: calendarConfigs.map { ($0.calendarIdentifier, $0) })
    }

    private var groupedEvents: [(group: EventTimeGroup, events: [CachedEvent])] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        var groups: [EventTimeGroup: [CachedEvent]] = [:]

        for event in cachedEvents {
            let group = EventTimeGroup.classify(date: event.startDate, today: today, calendar: calendar)
            groups[group, default: []].append(event)
        }

        return EventTimeGroup.allCases.compactMap { group in
            guard let events = groups[group], !events.isEmpty else { return nil }
            return (group: group, events: events)
        }
    }

    private var initialScrollTarget: EventTimeGroup? {
        let groups = groupedEvents.map(\.group)
        if groups.contains(.today) { return .today }
        // No "Today" section — pick the nearest section after today's position
        if let after = groups.first(where: { $0.rawValue > EventTimeGroup.today.rawValue }) {
            return after
        }
        return groups.last { $0.rawValue < EventTimeGroup.today.rawValue }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if cachedEvents.isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Synced events will appear here.")
                    )
                } else {
                    ForEach(groupedEvents, id: \.group) { section in
                        Section(section.group.title) {
                            ForEach(section.events, id: \.eventIdentifier) { event in
                                EventRow(event: event, prefix: configMap[event.calendarIdentifier]?.effectivePrefix)
                            }
                        }
                        .id(section.group)
                    }
                }
            }
            .onAppear {
                if let target = initialScrollTarget {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        .navigationTitle("Synced Events")
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: CachedEvent
    let prefix: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(.body)
                .lineLimit(2)

            Text(dateDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var displayTitle: String {
        if let prefix, !prefix.isEmpty {
            return "[\(prefix)] \(event.title)"
        }
        return event.title
    }

    private var dateDescription: String {
        if event.isAllDay {
            if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) ||
               event.endDate.timeIntervalSince(event.startDate) <= 86400 {
                return Self.dayFormatter.string(from: event.startDate)
            } else {
                let adjustedEnd = Calendar.current.date(byAdding: .day, value: -1, to: event.endDate) ?? event.endDate
                return "\(Self.dayFormatter.string(from: event.startDate)) – \(Self.dayFormatter.string(from: adjustedEnd))"
            }
        } else {
            if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
                return "\(Self.dayFormatter.string(from: event.startDate)), \(Self.timeFormatter.string(from: event.startDate)) – \(Self.timeFormatter.string(from: event.endDate))"
            } else {
                return "\(Self.dateTimeFormatter.string(from: event.startDate)) – \(Self.dateTimeFormatter.string(from: event.endDate))"
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Time Group Classification

enum EventTimeGroup: Int, CaseIterable {
    case yesterday
    case today
    case tomorrow
    case lastWeek
    case thisWeek
    case nextWeek
    case lastMonth
    case thisMonth
    case nextMonth
    case lastYear
    case thisYear
    case nextYear
    case furtherAhead
    case earlier

    var title: String {
        switch self {
        case .yesterday: "Yesterday"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .lastWeek: "Last Week"
        case .thisWeek: "This Week"
        case .nextWeek: "Next Week"
        case .lastMonth: "Last Month"
        case .thisMonth: "This Month"
        case .nextMonth: "Next Month"
        case .lastYear: "Last Year"
        case .thisYear: "This Year"
        case .nextYear: "Next Year"
        case .furtherAhead: "Further Ahead"
        case .earlier: "Earlier"
        }
    }

    static func classify(date: Date, today: Date, calendar: Calendar) -> EventTimeGroup {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!

        // Today / Yesterday / Tomorrow (exact day matches)
        if date >= today && date < tomorrow {
            return .today
        }
        if date >= yesterday && date < today {
            return .yesterday
        }
        if date >= tomorrow && date < dayAfterTomorrow {
            return .tomorrow
        }

        let startOfThisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let startOfNextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: startOfThisWeek)!
        let startOfWeekAfterNext = calendar.date(byAdding: .weekOfYear, value: 2, to: startOfThisWeek)!
        let startOfLastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfThisWeek)!

        // This week (excluding today/yesterday/tomorrow already matched)
        if date >= startOfThisWeek && date < startOfNextWeek {
            return .thisWeek
        }
        if date >= startOfLastWeek && date < startOfThisWeek {
            return .lastWeek
        }
        if date >= startOfNextWeek && date < startOfWeekAfterNext {
            return .nextWeek
        }

        let startOfThisMonth = calendar.dateInterval(of: .month, for: today)!.start
        let startOfNextMonth = calendar.date(byAdding: .month, value: 1, to: startOfThisMonth)!
        let startOfMonthAfterNext = calendar.date(byAdding: .month, value: 2, to: startOfThisMonth)!
        let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth)!

        if date >= startOfThisMonth && date < startOfNextMonth {
            return .thisMonth
        }
        if date >= startOfLastMonth && date < startOfThisMonth {
            return .lastMonth
        }
        if date >= startOfNextMonth && date < startOfMonthAfterNext {
            return .nextMonth
        }

        let startOfThisYear = calendar.dateInterval(of: .year, for: today)!.start
        let startOfNextYear = calendar.date(byAdding: .year, value: 1, to: startOfThisYear)!
        let startOfYearAfterNext = calendar.date(byAdding: .year, value: 2, to: startOfThisYear)!
        let startOfLastYear = calendar.date(byAdding: .year, value: -1, to: startOfThisYear)!

        if date >= startOfThisYear && date < startOfNextYear {
            return .thisYear
        }
        if date >= startOfLastYear && date < startOfThisYear {
            return .lastYear
        }
        if date >= startOfNextYear && date < startOfYearAfterNext {
            return .nextYear
        }

        if date >= startOfYearAfterNext {
            return .furtherAhead
        }

        return .earlier
    }
}

#Preview {
    NavigationStack {
        EventsOverviewView()
    }
    .modelContainer(for: [
        CachedEvent.self,
        CalendarSyncConfig.self,
    ], inMemory: true)
}
