import SwiftUI
import SwiftData

struct SyncLogView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SyncRecord.timestamp, order: .reverse) private var syncRecords: [SyncRecord]

    var body: some View {
        List {
            if syncRecords.isEmpty {
                ContentUnavailableView(
                    "No Sync History",
                    systemImage: "clock",
                    description: Text("Sync history will appear here after the first sync.")
                )
            } else {
                ForEach(syncRecords) { record in
                    NavigationLink {
                        SyncLogDetailsView(record: record)
                    } label: {
                        SyncLogRow(record: record)
                    }
                }
            }
        }
        .navigationTitle("Sync Log")
        .task {
            SyncRecord.deleteOlderThan(days: 10, context: modelContext)
        }
    }
}

private struct SyncLogRow: View {
    let record: SyncRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(record.isSuccess ? .green : .red)
                .font(.title2)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.isSuccess ? "Sync erfolgreich" : "Sync mit Fehlern")
                    .font(.subheadline.weight(.medium))

                Text(record.timestamp, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if record.createdCount > 0 {
                        Label("\(record.createdCount)", systemImage: SyncChangeType.created.iconName)
                            .font(.caption)
                            .foregroundStyle(SyncChangeType.created.color)
                    }
                    if record.updatedCount > 0 {
                        Label("\(record.updatedCount)", systemImage: SyncChangeType.updated.iconName)
                            .font(.caption)
                            .foregroundStyle(SyncChangeType.updated.color)
                    }
                    if record.deletedCount > 0 {
                        Label("\(record.deletedCount)", systemImage: SyncChangeType.deleted.iconName)
                            .font(.caption)
                            .foregroundStyle(SyncChangeType.deleted.color)
                    }
                    if record.totalChanges == 0 && record.isSuccess {
                        Text("No changes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if record.hasErrors {
                        let errorCount = record.messages.count(where: { $0.severity == .error })
                        if errorCount > 0 {
                            Label("\(errorCount)", systemImage: SyncChangeType.error.iconName)
                                .font(.caption)
                                .foregroundStyle(SyncChangeType.error.color)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("With Results") {
    NavigationStack {
        SyncLogView()
    }
    .modelContainer(previewModelContainer(populate: true))
}

#Preview("Empty") {
    NavigationStack {
        SyncLogView()
    }
    .modelContainer(previewModelContainer())
}

#Preview("Dark Mode") {
    NavigationStack {
        SyncLogView()
    }
    .modelContainer(previewModelContainer(populate: true))
    .preferredColorScheme(.dark)
}
#endif
