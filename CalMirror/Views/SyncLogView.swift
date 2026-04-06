import SwiftUI

struct SyncLogView: View {
    let syncResults: [SyncResult]

    var body: some View {
        List {
            if syncResults.isEmpty {
                ContentUnavailableView(
                    "No Sync History",
                    systemImage: "clock",
                    description: Text("Sync history will appear here after the first sync.")
                )
            } else {
                ForEach(Array(syncResults.enumerated()), id: \.offset) { _, result in
                    SyncLogRow(result: result)
                }
            }
        }
        .navigationTitle("Sync Log")
    }
}

private struct SyncLogRow: View {
    let result: SyncResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.errors.isEmpty ? .green : .orange)

                Text(result.timestamp, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(result.timestamp, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if result.created > 0 {
                    Label("\(result.created)", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if result.updated > 0 {
                    Label("\(result.updated)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                if result.deleted > 0 {
                    Label("\(result.deleted)", systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if result.totalChanges == 0 && result.errors.isEmpty {
                    Text("No changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !result.errors.isEmpty {
                ForEach(result.errors, id: \.self) { error in
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("With Results") {
    NavigationStack {
        SyncLogView(syncResults: PreviewData.syncResults)
    }
}

#Preview("Empty") {
    NavigationStack {
        SyncLogView(syncResults: [])
    }
}

#Preview("Dark Mode") {
    NavigationStack {
        SyncLogView(syncResults: PreviewData.syncResults)
    }
    .preferredColorScheme(.dark)
}
#endif
