import SwiftUI
import SwiftData
import EventKit

/// A single step in the time range picker, storing a calendar value and unit.
struct TimeRangeStep: Equatable {
    let value: Int
    let unit: String  // matches stored raw strings: "day", "weekOfYear", "month", "year"
    let label: String
}

/// Predefined time range steps the user can cycle through via Stepper.
private enum TimeRangeSteps {
    static let steps: [TimeRangeStep] = [
        TimeRangeStep(value: 1, unit: "day",        label: "1 day"),
        TimeRangeStep(value: 2, unit: "day",        label: "2 days"),
        TimeRangeStep(value: 3, unit: "day",        label: "3 days"),
        TimeRangeStep(value: 4, unit: "day",        label: "4 days"),
        TimeRangeStep(value: 5, unit: "day",        label: "5 days"),
        TimeRangeStep(value: 6, unit: "day",        label: "6 days"),
        TimeRangeStep(value: 1, unit: "weekOfYear", label: "1 week"),
        TimeRangeStep(value: 2, unit: "weekOfYear", label: "2 weeks"),
        TimeRangeStep(value: 3, unit: "weekOfYear", label: "3 weeks"),
        TimeRangeStep(value: 1, unit: "month",      label: "1 month"),
        TimeRangeStep(value: 2, unit: "month",      label: "2 months"),
        TimeRangeStep(value: 3, unit: "month",      label: "3 months"),
        TimeRangeStep(value: 4, unit: "month",      label: "4 months"),
        TimeRangeStep(value: 5, unit: "month",      label: "5 months"),
        TimeRangeStep(value: 6, unit: "month",      label: "½ year"),
        TimeRangeStep(value: 1, unit: "year",       label: "1 year"),
        TimeRangeStep(value: 18, unit: "month",     label: "1½ years"),
        TimeRangeStep(value: 2, unit: "year",       label: "2 years"),
        TimeRangeStep(value: 3, unit: "year",       label: "3 years"),
        TimeRangeStep(value: 4, unit: "year",       label: "4 years"),
    ]

    static func index(forValue value: Int, unit: String) -> Int {
        if let idx = steps.firstIndex(where: { $0.value == value && $0.unit == unit }) {
            return idx
        }
        // Fallback: find nearest by converting everything to approximate days
        let targetDays = approximateDays(value: value, unit: unit)
        return steps.indices.min(by: {
            abs(approximateDays(step: steps[$0]) - targetDays) <
            abs(approximateDays(step: steps[$1]) - targetDays)
        }) ?? 0
    }

    static func next(after index: Int) -> Int {
        min(index + 1, steps.count - 1)
    }

    static func previous(before index: Int) -> Int {
        max(index - 1, 0)
    }

    static func isAtMin(_ index: Int) -> Bool {
        index <= 0
    }

    static func isAtMax(_ index: Int) -> Bool {
        index >= steps.count - 1
    }

    private static func approximateDays(step: TimeRangeStep) -> Int {
        approximateDays(value: step.value, unit: step.unit)
    }

    private static func approximateDays(value: Int, unit: String) -> Int {
        switch unit {
        case "day": return value
        case "weekOfYear": return value * 7
        case "month": return value * 30
        case "year": return value * 365
        default: return value
        }
    }
}

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
                    ForEach(Array(cals.enumerated()), id: \.element.calendarIdentifier) { index, calendar in
                        Section {
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
                                },
                                onPastChanged: { step in
                                    updatePast(calendar: calendar, step: step)
                                },
                                onFutureChanged: { step in
                                    updateFuture(calendar: calendar, step: step)
                                }
                            )
                        } header: {
                            if index == 0 {
                                Text(source)
                            }
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

    private func updatePast(calendar: EKCalendar, step: TimeRangeStep) {
        let config = getOrCreateConfig(for: calendar)
        config.pastValue = step.value
        config.pastUnit = step.unit
        try? modelContext.save()
    }

    private func updateFuture(calendar: EKCalendar, step: TimeRangeStep) {
        let config = getOrCreateConfig(for: calendar)
        config.futureValue = step.value
        config.futureUnit = step.unit
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
    let onPastChanged: (TimeRangeStep) -> Void
    let onFutureChanged: (TimeRangeStep) -> Void

    @State private var isEnabled: Bool = false
    @State private var isPrefixEnabled: Bool = false
    @State private var prefixText: String = ""
    @State private var pastIndex: Int = 0
    @State private var futureIndex: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .padding(.top, 8)
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

                Divider()
                    .padding(.leading, 20)
                    .padding(.top, 8)

                // Past limit
                timeRangeStepper(
                    title: "Past",
                    label: TimeRangeSteps.steps[pastIndex].label,
                    isAtMin: TimeRangeSteps.isAtMin(pastIndex),
                    isAtMax: TimeRangeSteps.isAtMax(pastIndex),
                    onDecrement: {
                        pastIndex = TimeRangeSteps.previous(before: pastIndex)
                        onPastChanged(TimeRangeSteps.steps[pastIndex])
                    },
                    onIncrement: {
                        pastIndex = TimeRangeSteps.next(after: pastIndex)
                        onPastChanged(TimeRangeSteps.steps[pastIndex])
                    }
                )

                // Future limit
                timeRangeStepper(
                    title: "Future",
                    label: TimeRangeSteps.steps[futureIndex].label,
                    isAtMin: TimeRangeSteps.isAtMin(futureIndex),
                    isAtMax: TimeRangeSteps.isAtMax(futureIndex),
                    onDecrement: {
                        futureIndex = TimeRangeSteps.previous(before: futureIndex)
                        onFutureChanged(TimeRangeSteps.steps[futureIndex])
                    },
                    onIncrement: {
                        futureIndex = TimeRangeSteps.next(after: futureIndex)
                        onFutureChanged(TimeRangeSteps.steps[futureIndex])
                    }
                )
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            isEnabled = config?.isEnabled ?? false
            isPrefixEnabled = config?.isPrefixEnabled ?? false
            prefixText = config?.customPrefix ?? calendar.title
            pastIndex = TimeRangeSteps.index(
                forValue: config?.pastValue ?? 1,
                unit: config?.pastUnit ?? "weekOfYear"
            )
            futureIndex = TimeRangeSteps.index(
                forValue: config?.futureValue ?? 1,
                unit: config?.futureUnit ?? "year"
            )
        }
    }

    @ViewBuilder
    private func timeRangeStepper(
        title: String,
        label: String,
        isAtMin: Bool,
        isAtMax: Bool,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void
    ) -> some View {
        HStack {
            Text("\(title): \(label)")
                .font(.subheadline)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    onDecrement()
                } label: {
                    Image(systemName: "minus")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(isAtMin)

                Divider()
                    .frame(height: 16)

                Button {
                    onIncrement()
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(isAtMax)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.leading, 20)
    }
}
