import SwiftUI

struct SyncLogDetailsView: View {
    let record: SyncRecord

    private var groupedEntries: [(type: SyncChangeType, entries: [SyncRecordEntry])] {
        let groups = Dictionary(grouping: record.entries, by: \.changeType)
        return [SyncChangeType.created, .updated, .deleted, .error].compactMap { type in
            guard let entries = groups[type], !entries.isEmpty else { return nil }
            return (type: type, entries: entries)
        }
    }

    var body: some View {
        List {
            // Header
            Section {
                HStack(spacing: 12) {
                    Image(systemName: record.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(record.isSuccess ? .green : .red)
                        .font(.largeTitle)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.isSuccess ? "Sync erfolgreich" : "Sync mit Fehlern")
                            .font(.headline)
                        Text(record.timestamp, format: .dateTime.day().month().year().hour().minute().second())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(record.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Event changes grouped by type
            if !record.entries.isEmpty {
                ForEach(groupedEntries, id: \.type) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.changeType.iconName)
                                    .foregroundStyle(entry.changeType.color)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.body)
                                    if let error = entry.errorMessage {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    } header: {
                        Label(group.type.displayName, systemImage: group.type.iconName)
                            .foregroundStyle(group.type.color)
                    }
                }
            } else if record.totalChanges == 0 && record.isSuccess {
                Section("Events") {
                    Text("No changes")
                        .foregroundStyle(.secondary)
                }
            }

            // Log messages
            if !record.messages.isEmpty {
                Section("Log") {
                    ForEach(record.messages) { message in
                        HStack(spacing: 10) {
                            Image(systemName: message.severity.iconName)
                                .foregroundStyle(message.severity.color)
                                .frame(width: 20)

                            Text(message.text)
                                .font(.caption)
                                .foregroundStyle(message.severity == .error ? .red : .primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sync Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Success") {
    NavigationStack {
        SyncLogDetailsView(record: PreviewData.syncRecordSuccess)
    }
}

#Preview("With Errors") {
    NavigationStack {
        SyncLogDetailsView(record: PreviewData.syncRecordWithErrors)
    }
}

#Preview("No Changes") {
    NavigationStack {
        SyncLogDetailsView(record: PreviewData.syncRecordNoChanges)
    }
}

#Preview("Dark Mode") {
    NavigationStack {
        SyncLogDetailsView(record: PreviewData.syncRecordSuccess)
    }
    .preferredColorScheme(.dark)
}
#endif
