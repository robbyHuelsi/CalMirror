import SwiftUI
import SwiftData

@main
struct CalMirrorApp: App {
    private let eventStore: ReadOnlyEventStore
    @State private var syncScheduler: SyncScheduler

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CachedEvent.self,
            ServerConfiguration.self,
            CalendarSyncConfig.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Schema migration failed — delete the incompatible store and retry
            let storeURL = modelConfiguration.url
            let related = [
                storeURL,
                storeURL.appendingPathExtension("shm"),
                storeURL.appendingPathExtension("wal"),
            ]
            for url in related {
                try? FileManager.default.removeItem(at: url)
            }
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }()

    init() {
        let store = ReadOnlyEventStore()
        self.eventStore = store
        let engine = SyncEngine(eventStore: store)
        self.syncScheduler = SyncScheduler(eventStore: store, syncEngine: engine)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(eventStore: eventStore)
                .environment(syncScheduler)
                .task {
                    await startScheduler()
                }
        }
        .modelContainer(sharedModelContainer)
        #if os(iOS)
        .backgroundTask(.appRefresh("calMirrorSync")) {
            await handleBackgroundSync()
        }
        #endif
    }

    @MainActor
    private func startScheduler() async {
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<ServerConfiguration>(
            predicate: #Predicate { $0.isActive }
        )
        let interval = (try? context.fetch(descriptor))?.first?.syncIntervalMinutes ?? 30
        syncScheduler.start(intervalMinutes: interval)
    }

    #if os(iOS)
    private func handleBackgroundSync() async {
        let context = ModelContext(sharedModelContainer)
        _ = await syncScheduler.triggerSync(modelContext: context)
    }
    #endif
}
