import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncScheduler.self) private var syncScheduler
    @Query(filter: #Predicate<CalendarSyncConfig> { $0.isEnabled }) private var enabledCalendars: [CalendarSyncConfig]
    @Query private var cachedEvents: [CachedEvent]
    @Query private var serverConfigs: [ServerConfiguration]

    let eventStore: EventReading

    @State private var syncHistory: [SyncResult] = []
    @State private var isSyncing = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                syncSection
                settingsSection
            }
            .navigationTitle("CalMirror")
            .onReceive(NotificationCenter.default.publisher(for: .calendarDidChange)) { _ in
                Task { await autoSync() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scheduledSyncDidFire)) { _ in
                Task { await autoSync() }
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Label("Synced Events", systemImage: "calendar")
                Spacer()
                Text("\(cachedEvents.count)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Active Calendars", systemImage: "checklist")
                Spacer()
                Text("\(enabledCalendars.count)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Server", systemImage: "server.rack")
                Spacer()
                if let server = serverConfigs.first {
                    Text(server.displayName)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not configured")
                        .foregroundStyle(.red)
                }
            }

            if let lastSync = syncScheduler.lastSyncDate {
                HStack {
                    Label("Last Sync", systemImage: "clock")
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastResult = syncScheduler.syncEngine.lastSyncResult {
                HStack {
                    Label("Last Result", systemImage: lastResult.errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    Spacer()
                    Text(lastResult.summary)
                        .font(.caption)
                        .foregroundStyle(lastResult.errors.isEmpty ? .secondary : Color.orange)
                }
            }
        }
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section("Sync") {
            Button {
                Task { await manualSync() }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isSyncing || serverConfigs.isEmpty || enabledCalendars.isEmpty)

            if serverConfigs.isEmpty {
                Label("Configure a server first", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if enabledCalendars.isEmpty {
                Label("Select calendars to sync", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        Section("Settings") {
            NavigationLink {
                ServerSettingsView()
            } label: {
                Label("Server Configuration", systemImage: "server.rack")
            }

            NavigationLink {
                CalendarSelectionView(eventStore: eventStore)
            } label: {
                Label("Calendars", systemImage: "calendar")
            }

            NavigationLink {
                SyncLogView(syncResults: syncHistory)
            } label: {
                Label("Sync Log", systemImage: "list.bullet.clipboard")
            }
        }
    }

    // MARK: - Sync Actions

    private func manualSync() async {
        isSyncing = true
        let result = await syncScheduler.triggerSync(modelContext: modelContext)
        syncHistory.insert(result, at: 0)
        if syncHistory.count > 50 {
            syncHistory = Array(syncHistory.prefix(50))
        }
        isSyncing = false
    }

    private func autoSync() async {
        guard !isSyncing else { return }
        await manualSync()
    }
}

#Preview {
    ContentView(eventStore: ReadOnlyEventStore())
        .modelContainer(for: [
            CachedEvent.self,
            ServerConfiguration.self,
            CalendarSyncConfig.self,
        ], inMemory: true)
        .environment(SyncScheduler(
            eventStore: ReadOnlyEventStore(),
            syncEngine: SyncEngine(eventStore: ReadOnlyEventStore())
        ))
}
