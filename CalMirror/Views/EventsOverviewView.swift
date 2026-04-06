import SwiftUI
import SwiftData

struct EventsOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncScheduler.self) private var syncScheduler

    @State private var syncPlan: SyncPlan?
    @State private var isAnalyzing = false
    @State private var deleteConfirmation: SyncPlanEntry?
    @State private var activeFilter: EventSyncStatus?

    init(initialSyncPlan: SyncPlan? = nil) {
        _syncPlan = State(initialValue: initialSyncPlan)
    }

    private var displayEntries: [SyncPlanEntry] {
        let all = syncPlan?.entries ?? []
        guard let filter = activeFilter else { return all }
        return all.filter { $0.status == filter }
    }

    private var groupedEntries: [(group: EventTimeGroup, entries: [SyncPlanEntry])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var groups: [EventTimeGroup: [SyncPlanEntry]] = [:]

        for entry in displayEntries {
            // Orphaned events without valid dates go into a special section
            if entry.status == .orphaned && entry.startDate == .distantPast {
                groups[.earlier, default: []].append(entry)
                continue
            }
            let group = EventTimeGroup.classify(date: entry.startDate, today: today, calendar: calendar)
            groups[group, default: []].append(entry)
        }

        return EventTimeGroup.allCases.compactMap { group in
            guard let entries = groups[group], !entries.isEmpty else { return nil }
            let sorted = entries.sorted { $0.startDate < $1.startDate }
            return (group: group, entries: sorted)
        }
    }

    private var initialScrollTarget: EventTimeGroup? {
        let groups = groupedEntries.map(\.group)
        if groups.contains(.today) { return .today }
        if let after = groups.first(where: { $0.rawValue > EventTimeGroup.today.rawValue }) {
            return after
        }
        return groups.last { $0.rawValue < EventTimeGroup.today.rawValue }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if isAnalyzing && syncPlan == nil {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Analyzing…")
                            Spacer()
                        }
                    }
                } else if (syncPlan?.entries ?? []).isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Synced events will appear here.")
                    )
                } else {
                    if let plan = syncPlan, !plan.errors.isEmpty {
                        Section {
                            ForEach(plan.errors, id: \.self) { error in
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if displayEntries.isEmpty {
                        ContentUnavailableView(
                            "No \(activeFilter?.displayName ?? "") Events",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("No events match the selected filter.")
                        )
                    }
                    ForEach(groupedEntries, id: \.group) { section in
                        Section(section.group.title) {
                            ForEach(section.entries) { entry in
                                EventRow(entry: entry)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if entry.status == .orphaned, let uid = entry.remoteUID {
                                            Button(role: .destructive) {
                                                deleteConfirmation = entry
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                        }
                        .id(section.group)
                    }
                }
            }
            .task {
                if syncPlan == nil { await analyze() }
            }
            .refreshable {
                await analyze()
            }
            .onAppear {
                if syncPlan != nil, let target = initialScrollTarget {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
            .onChange(of: syncPlan != nil) {
                if let target = initialScrollTarget {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let plan = syncPlan, !(syncPlan?.entries ?? []).isEmpty {
                    statusBar(plan)
                }
            }
        }
        .navigationTitle("Events")
        .alert("Delete from Server?", isPresented: .init(
            get: { deleteConfirmation != nil },
            set: { if !$0 { deleteConfirmation = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteConfirmation = nil }
            Button("Delete", role: .destructive) {
                if let entry = deleteConfirmation, let uid = entry.remoteUID {
                    Task { await deleteOrphan(uid: uid) }
                }
            }
        } message: {
            Text("This will permanently remove \"\(deleteConfirmation?.title ?? "")\" from the server.")
        }
    }

    @ViewBuilder
    private func statusBar(_ plan: SyncPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusBadge(status: .synced, count: plan.syncedCount, activeFilter: activeFilter) {
                    withAnimation { activeFilter = activeFilter == .synced ? nil : .synced }
                }
                StatusBadge(status: .pending, count: plan.pendingCount, activeFilter: activeFilter) {
                    withAnimation { activeFilter = activeFilter == .pending ? nil : .pending }
                }
                StatusBadge(status: .modified, count: plan.modifiedCount, activeFilter: activeFilter) {
                    withAnimation { activeFilter = activeFilter == .modified ? nil : .modified }
                }
                StatusBadge(status: .pendingDelete, count: plan.pendingDeleteCount, activeFilter: activeFilter) {
                    withAnimation { activeFilter = activeFilter == .pendingDelete ? nil : .pendingDelete }
                }
                StatusBadge(status: .orphaned, count: plan.orphanedCount, activeFilter: activeFilter) {
                    withAnimation { activeFilter = activeFilter == .orphaned ? nil : .orphaned }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .glassEffect(.regular.interactive())
    }

    private func analyze() async {
        isAnalyzing = true
        syncPlan = await syncScheduler.syncEngine.analyzeSyncPlan(modelContext: modelContext)
        isAnalyzing = false
    }

    private func deleteOrphan(uid: String) async {
        do {
            // Load server config to create a client
            let descriptor = FetchDescriptor<ServerConfiguration>(
                predicate: #Predicate { $0.isActive }
            )
            guard let serverConfig = try? modelContext.fetch(descriptor).first,
                  let password = KeychainHelper.load(service: serverConfig.keychainServiceID, account: serverConfig.username) else {
                return
            }
            let client = try CalDAVClient(
                serverURL: serverConfig.serverURL,
                calendarPath: serverConfig.calendarPath,
                username: serverConfig.username,
                password: password
            )
            try await client.deleteEvent(uid: uid)
            // Re-analyze to refresh the view
            await analyze()
        } catch {
            // Error is logged by CalDAVClient
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: EventSyncStatus
    let count: Int
    let activeFilter: EventSyncStatus?
    let onTap: () -> Void

    private var color: Color {
        switch status {
        case .synced: .green
        case .modified: .orange
        case .pending: .blue
        case .pendingDelete: .orange
        case .orphaned: .red
        }
    }

    private var isActive: Bool { activeFilter == status }
    private var isFiltered: Bool { activeFilter != nil && !isActive }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: status.iconName)
                    .foregroundStyle(color)
                Text("\(count)")
                    .fontWeight(isActive ? .bold : .regular)
            }
            .font(.caption)
            Text(status.displayName)
                .font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isActive ? color.opacity(0.2) : Color.clear)
        )
        .opacity(isFiltered ? 0.4 : 1.0)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let entry: SyncPlanEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.body)
                    .lineLimit(2)

                if entry.startDate != .distantPast {
                    Text(dateDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            Spacer()

            Image(systemName: entry.status.iconName)
                .foregroundStyle(statusColor)
                .font(.body)
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .synced: .green
        case .modified: .orange
        case .pending: .blue
        case .pendingDelete: .orange
        case .orphaned: .red
        }
    }

    private var displayTitle: String {
        if let prefix = entry.prefix, !prefix.isEmpty {
            return "[\(prefix)] \(entry.title)"
        }
        return entry.title
    }

    private var dateDescription: String {
        if entry.isAllDay {
            if Calendar.current.isDate(entry.startDate, inSameDayAs: entry.endDate) ||
               entry.endDate.timeIntervalSince(entry.startDate) <= 86400 {
                return Self.dayFormatter.string(from: entry.startDate)
            } else {
                let adjustedEnd = Calendar.current.date(byAdding: .day, value: -1, to: entry.endDate) ?? entry.endDate
                return "\(Self.dayFormatter.string(from: entry.startDate)) – \(Self.dayFormatter.string(from: adjustedEnd))"
            }
        } else {
            if Calendar.current.isDate(entry.startDate, inSameDayAs: entry.endDate) {
                return "\(Self.dayFormatter.string(from: entry.startDate)), \(Self.timeFormatter.string(from: entry.startDate)) – \(Self.timeFormatter.string(from: entry.endDate))"
            } else {
                return "\(Self.dateTimeFormatter.string(from: entry.startDate)) – \(Self.dateTimeFormatter.string(from: entry.endDate))"
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
    case earlier
    case lastYear
    case lastMonth
    case lastWeek
    case yesterday
    case today
    case tomorrow
    case thisWeek
    case nextWeek
    case thisMonth
    case nextMonth
    case thisYear
    case nextYear
    case furtherAhead

    var title: String {
        switch self {
        case .earlier: "Earlier"
        case .lastYear: "Last Year"
        case .lastMonth: "Last Month"
        case .lastWeek: "Last Week"
        case .yesterday: "Yesterday"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This Week"
        case .nextWeek: "Next Week"
        case .thisMonth: "This Month"
        case .nextMonth: "Next Month"
        case .thisYear: "This Year"
        case .nextYear: "Next Year"
        case .furtherAhead: "Further Ahead"
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

#if DEBUG
#Preview("With Events") {
    NavigationStack {
        EventsOverviewView(initialSyncPlan: PreviewData.samplePlan)
    }
    .modelContainer(previewModelContainer(populate: true))
    .environment(previewSyncScheduler())
}

#Preview("Empty") {
    NavigationStack {
        EventsOverviewView()
    }
    .modelContainer(previewModelContainer())
    .environment(previewSyncScheduler())
}

#Preview("Dark Mode") {
    NavigationStack {
        EventsOverviewView(initialSyncPlan: PreviewData.samplePlan)
    }
    .modelContainer(previewModelContainer(populate: true))
    .environment(previewSyncScheduler())
    .preferredColorScheme(.dark)
}
#endif
