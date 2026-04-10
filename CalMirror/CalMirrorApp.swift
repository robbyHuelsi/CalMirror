import SwiftUI
import SwiftData

@main
struct CalMirrorApp: App {
    private let eventStore: ReadOnlyEventStore
    @State private var syncScheduler: SyncScheduler
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: CachedEvent.self, ServerConfiguration.self, CalendarSyncConfig.self, SyncRecord.self,
                migrationPlan: CalMirrorMigrationPlan.self
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
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
                .fullScreenCover(isPresented: Binding(
                    get: { !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    WelcomeWizardView(
                        hasCompletedOnboarding: $hasCompletedOnboarding,
                        eventStore: eventStore
                    )
                    .environment(syncScheduler)
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
