import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncScheduler.self) private var syncScheduler
    @Query(filter: #Predicate<CalendarSyncConfig> { $0.isEnabled }) private var enabledCalendars: [CalendarSyncConfig]
    @Query private var cachedEvents: [CachedEvent]
    @Query private var serverConfigs: [ServerConfiguration]

    let eventStore: EventReading

    @State private var syncHistory: [SyncResult] = []
    @State private var isSyncing = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var settingsDocument: SettingsDocument?
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                syncSection
                settingsSection
            }
            .navigationTitle("CalMirror")
            .fileExporter(
                isPresented: $showExporter,
                document: settingsDocument,
                contentType: .json,
                defaultFilename: "CalMirror-Settings.json"
            ) { result in
                if case .failure(let error) = result {
                    importMessage = "Export failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .data]
            ) { result in
                importSettings(result: result)
            }
            .alert("Settings", isPresented: .init(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
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
        Section {
            HStack {
                Label("Synced Events", systemImage: "calendar")
                Spacer()
                Text("\(cachedEvents.count)")
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                CalendarSelectionView(eventStore: eventStore)
            } label: {
                HStack {
                    Label("Active Calendars", systemImage: "checklist")
                    Spacer()
                    Text("\(enabledCalendars.count)")
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                ServerSettingsView()
            } label: {
                HStack {
                    Label("Server", systemImage: "server.rack")
                    Spacer()
                    if let server = serverConfigs.first {
                        Text(server.serverURL)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not configured")
                            .foregroundStyle(.red)
                    }
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
        Section {
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
        Section("Developer Tools") {
            NavigationLink {
                SyncLogView(syncResults: syncHistory)
            } label: {
                Label("Sync Log", systemImage: "list.bullet.clipboard")
            }

            Button {
                exportSettings()
            } label: {
                Label("Export Settings", systemImage: "square.and.arrow.up")
            }

            Button {
                showImporter = true
            } label: {
                Label("Import Settings", systemImage: "square.and.arrow.down")
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

    // MARK: - Export/Import

    private func exportSettings() {
        do {
            let export = try SettingsExport.from(modelContext: modelContext)
            settingsDocument = try SettingsDocument(export: export)
            showExporter = true
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                importMessage = "Could not access file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let export = try decoder.decode(SettingsExport.self, from: data)
                try export.apply(to: modelContext)
                importMessage = "Settings imported successfully. Please enter your password in Server Configuration."
            } catch {
                importMessage = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            importMessage = "Import failed: \(error.localizedDescription)"
        }
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
