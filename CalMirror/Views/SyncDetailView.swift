import SwiftUI
import SwiftData

struct SyncDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncScheduler.self) private var syncScheduler
    @Query private var serverConfigs: [ServerConfiguration]
    @Query(filter: #Predicate<CalendarSyncConfig> { $0.isEnabled }) private var enabledCalendars: [CalendarSyncConfig]

    @Binding var syncHistory: [SyncResult]
    @Binding var isSyncing: Bool

    var body: some View {
        Form {
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

            Section {
                if let lastSync = syncScheduler.lastSyncDate {
                    HStack {
                        Label("Last Sync", systemImage: "clock")
                        Spacer()
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Label("Last Sync", systemImage: "clock")
                        Spacer()
                        Text("Never")
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
        .navigationTitle("Synchronization")
    }

    private func manualSync() async {
        isSyncing = true
        let result = await syncScheduler.triggerSync(modelContext: modelContext)
        syncHistory.insert(result, at: 0)
        if syncHistory.count > 50 {
            syncHistory = Array(syncHistory.prefix(50))
        }
        isSyncing = false
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Idle") {
    NavigationStack {
        SyncDetailView(
            syncHistory: .constant([]),
            isSyncing: .constant(false)
        )
    }
    .modelContainer(previewModelContainer(populate: true))
    .environment(previewSyncScheduler())
}

#Preview("After Sync") {
    NavigationStack {
        SyncDetailView(
            syncHistory: .constant(PreviewData.syncResults),
            isSyncing: .constant(false)
        )
    }
    .modelContainer(previewModelContainer(populate: true))
    .environment(previewSyncScheduler(
        lastSyncDate: Date().addingTimeInterval(-120),
        lastSyncResult: PreviewData.syncResults.first
    ))
}

#Preview("Syncing") {
    NavigationStack {
        SyncDetailView(
            syncHistory: .constant(PreviewData.syncResults),
            isSyncing: .constant(true)
        )
    }
    .modelContainer(previewModelContainer(populate: true))
    .environment(previewSyncScheduler(
        lastSyncDate: Date().addingTimeInterval(-120),
        lastSyncResult: PreviewData.syncResults.first
    ))
}

#Preview("Dark Mode") {
    NavigationStack {
        SyncDetailView(
            syncHistory: .constant(PreviewData.syncResults),
            isSyncing: .constant(false)
        )
    }
    .modelContainer(previewModelContainer(populate: true))
    .environment(previewSyncScheduler(
        lastSyncDate: Date().addingTimeInterval(-120),
        lastSyncResult: PreviewData.syncResults.first
    ))
    .preferredColorScheme(.dark)
}
#endif
