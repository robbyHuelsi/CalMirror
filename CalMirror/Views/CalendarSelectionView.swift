import SwiftUI
import SwiftData
import EventKit

struct CalendarSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var syncConfigs: [CalendarSyncConfig]

    let eventStore: EventReading

    @State private var calendars: [EKCalendar] = []
    @State private var hasAccess = false
    @State private var isDenied = false
    @State private var isRequestingAccess = false

    var body: some View {
        List {
            if !hasAccess {
                accessSection
            } else if calendars.isEmpty {
                ContentUnavailableView(
                    "No Calendars",
                    systemImage: "calendar",
                    description: Text("No calendars found on this device.")
                )
            } else {
                ForEach(calendarsBySource, id: \.key) { source, cals in
                    Section(source) {
                        ForEach(cals, id: \.calendarIdentifier) { calendar in
                            CalendarRow(
                                calendar: calendar,
                                config: configFor(calendar),
                                onToggleSync: { enabled in
                                    toggleSync(calendar: calendar, enabled: enabled)
                                },
                                onTogglePrefix: { enabled in
                                    togglePrefix(calendar: calendar, enabled: enabled)
                                },
                                onPrefixChanged: { prefix in
                                    updatePrefix(calendar: calendar, prefix: prefix)
                                }
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Calendars")
        .task {
            await checkAccess()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await checkAccess() }
            }
        }
    }

    // MARK: - Access Section

    private var accessSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: isDenied ? "calendar.badge.minus" : "calendar.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                if isDenied {
                    Text("Calendar access was denied. Please enable it in the Settings app to continue.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    #if os(iOS) || os(visionOS)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    #elseif os(macOS)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    #endif
                } else {
                    Text("Calendar access is required to read your events.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Grant Access") {
                        Task { await requestAccess() }
                    }
                    .disabled(isRequestingAccess)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    // MARK: - Helpers

    private var calendarsBySource: [(key: String, value: [EKCalendar])] {
        let grouped = Dictionary(grouping: calendars) { $0.source?.title ?? "Other" }
        return grouped.sorted { $0.key < $1.key }
    }

    private func configFor(_ calendar: EKCalendar) -> CalendarSyncConfig? {
        syncConfigs.first { $0.calendarIdentifier == calendar.calendarIdentifier }
    }

    private func checkAccess() async {
        let status = eventStore.authorizationStatus()
        hasAccess = status == .fullAccess
        isDenied = status == .denied || status == .restricted
        if hasAccess {
            calendars = eventStore.availableCalendars()
        }
    }

    private func requestAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }

        do {
            hasAccess = try await eventStore.requestAccess()
            if hasAccess {
                calendars = eventStore.availableCalendars()
            } else {
                isDenied = true
            }
        } catch {
            hasAccess = false
            isDenied = true
        }
    }

    private func toggleSync(calendar: EKCalendar, enabled: Bool) {
        let config = getOrCreateConfig(for: calendar)
        config.isEnabled = enabled
        try? modelContext.save()
    }

    private func togglePrefix(calendar: EKCalendar, enabled: Bool) {
        let config = getOrCreateConfig(for: calendar)
        config.isPrefixEnabled = enabled
        try? modelContext.save()
    }

    private func updatePrefix(calendar: EKCalendar, prefix: String) {
        let config = getOrCreateConfig(for: calendar)
        config.customPrefix = prefix.isEmpty ? nil : prefix
        try? modelContext.save()
    }

    private func getOrCreateConfig(for calendar: EKCalendar) -> CalendarSyncConfig {
        if let existing = syncConfigs.first(where: { $0.calendarIdentifier == calendar.calendarIdentifier }) {
            return existing
        }
        let config = CalendarSyncConfig(
            calendarIdentifier: calendar.calendarIdentifier,
            calendarName: calendar.title
        )
        modelContext.insert(config)
        return config
    }
}

// MARK: - Calendar Row

private struct CalendarRow: View {
    let calendar: EKCalendar
    let config: CalendarSyncConfig?
    let onToggleSync: (Bool) -> Void
    let onTogglePrefix: (Bool) -> Void
    let onPrefixChanged: (String) -> Void

    @State private var isEnabled: Bool = false
    @State private var isPrefixEnabled: Bool = false
    @State private var prefixText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isEnabled) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(cgColor: calendar.cgColor))
                        .frame(width: 12, height: 12)
                    Text(calendar.title)
                }
            }
            .onChange(of: isEnabled) { _, newValue in
                onToggleSync(newValue)
            }

            if isEnabled {
                Toggle("Prefix", isOn: $isPrefixEnabled)
                    .font(.subheadline)
                    .padding(.leading, 20)
                    .onChange(of: isPrefixEnabled) { _, newValue in
                        onTogglePrefix(newValue)
                        if newValue && prefixText.isEmpty {
                            prefixText = calendar.title
                        }
                    }

                if isPrefixEnabled {
                    TextField("Prefix", text: $prefixText)
                        .font(.subheadline)
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 20)
                        .onChange(of: prefixText) { _, newValue in
                            onPrefixChanged(newValue)
                        }

                    Text("Preview: [\(prefixText.isEmpty ? calendar.title : prefixText)] Event Title")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            isEnabled = config?.isEnabled ?? false
            isPrefixEnabled = config?.isPrefixEnabled ?? false
            prefixText = config?.customPrefix ?? calendar.title
        }
    }
}
