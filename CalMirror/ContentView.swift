import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine

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
    @AppStorage("showDeveloperTools") private var showDeveloperTools = false
    @AppStorage("navigateToEventsOverview") private var navigateToEventsOverview = false
    @AppStorage("navigateToEventsOverviewOrphaned") private var navigateToEventsOverviewOrphaned = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 24) {
                    tileGrid
                    if showDeveloperTools {
                        settingsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .refreshable {
                await autoSync()
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
            .navigationDestination(for: String.self) { destination in
                switch destination {
                case "eventsOverview":
                    EventsOverviewView()
                case "eventsOverviewOrphaned":
                    EventsOverviewView(delayedFilter: .orphaned)
                default:
                    EmptyView()
                }
            }
            .onChange(of: navigateToEventsOverviewOrphaned) { _, shouldNavigate in
                guard shouldNavigate else { return }
                navigateToEventsOverviewOrphaned = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation {
                        path.append("eventsOverviewOrphaned")
                    }
                }
            }
            .onChange(of: navigateToEventsOverview) { _, shouldNavigate in
                guard shouldNavigate else { return }
                navigateToEventsOverview = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation {
                        path.append("eventsOverview")
                    }
                }
            }
        }
    }

    // MARK: - Tile Grid

    private var tileGrid: some View {
        VStack(spacing: 12) {
            NavigationLink {
                EventsOverviewView()
            } label: {
                GlassTileView(
                    systemImage: "calendar",
                    title: "Synced Events",
                    subtitleText: "\(cachedEvents.count) events",
                    tintColor: .blue
                )
            }

            NavigationLink {
                CalendarSelectionView(eventStore: eventStore)
            } label: {
                GlassTileView(
                    systemImage: "checklist",
                    title: "Active Calendars",
                    subtitleText: "\(enabledCalendars.count) calendars",
                    tintColor: .green
                )
            }

            NavigationLink {
                ServerSettingsView()
            } label: {
                GlassTileView(
                    systemImage: "server.rack",
                    title: "Server",
                    subtitleText: serverConfigs.first?.serverURL ?? "Not configured",
                    tintColor: .orange
                )
            }

            NavigationLink {
                SyncDetailView(syncHistory: $syncHistory, isSyncing: $isSyncing)
            } label: {
                GlassTileView(systemImage: "arrow.triangle.2.circlepath", title: "Synchronization", tintColor: .purple) {
                    if let lastSync = syncScheduler.lastSyncDate {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(coarseRelativeTime(from: lastSync, now: context.date))
                        }
                    } else {
                        Text("Never")
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer Tools")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                NavigationLink {
                    SyncLogView(syncResults: syncHistory)
                } label: {
                    Label("Sync Log", systemImage: "list.bullet.clipboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }

                Divider().padding(.leading, 16)

                Button {
                    exportSettings()
                } label: {
                    Label("Export Settings", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }

                Divider().padding(.leading, 16)

                Button {
                    showImporter = true
                } label: {
                    Label("Import Settings", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }

                Divider().padding(.leading, 16)

                Button(role: .destructive) {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    UserDefaults.standard.set(false, forKey: "navigateToEventsOverview")
                    UserDefaults.standard.set(false, forKey: "navigateToEventsOverviewOrphaned")
                    exit(0)
                } label: {
                    Label("Restart App into Welcome Wizard", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
            }
            .buttonStyle(.plain)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - Auto Sync

    private func coarseRelativeTime(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 {
            return "< 1 min ago"
        } else if seconds < 3600 {
            return "\(seconds / 60) min ago"
        } else if seconds < 86400 {
            return "\(seconds / 3600) hr ago"
        } else {
            return "\(seconds / 86400) days ago"
        }
    }

    private func autoSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        let result = await syncScheduler.triggerSync(modelContext: modelContext)
        syncHistory.insert(result, at: 0)
        if syncHistory.count > 50 {
            syncHistory = Array(syncHistory.prefix(50))
        }
        isSyncing = false
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

#if DEBUG
#Preview("Fresh Install") {
    ContentView(eventStore: MockEventStore())
        .modelContainer(previewModelContainer())
        .environment(previewSyncScheduler())
}

#Preview("Configured") {
    ContentView(eventStore: MockEventStore())
        .modelContainer(previewModelContainer(populate: true))
        .environment(previewSyncScheduler())
}

#Preview("Dark Mode") {
    ContentView(eventStore: MockEventStore())
        .modelContainer(previewModelContainer(populate: true))
        .environment(previewSyncScheduler())
        .preferredColorScheme(.dark)
}
#endif
