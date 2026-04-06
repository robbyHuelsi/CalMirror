import SwiftUI
import SwiftData
import EventKit

struct WelcomeWizardView: View {
    @Binding var hasCompletedOnboarding: Bool
    let eventStore: EventReading
    let initialCalendars: [CalendarInfo]?

    init(hasCompletedOnboarding: Binding<Bool>, eventStore: EventReading, initialCalendars: [CalendarInfo]? = nil) {
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self.eventStore = eventStore
        self.initialCalendars = initialCalendars
    }

    @State private var currentStep = 0
    @State private var hasCalendarAccess = false
    @State private var isCalendarDenied = false
    @State private var isRequestingAccess = false
    @State private var privacyAcknowledged = false
    @State private var highlightPrivacyButton = false

    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            progressIndicator
                .padding(.top, 16)
                .padding(.bottom, 8)

            // Page content
            TabView(selection: $currentStep) {
                welcomePage.tag(0)
                privacyPage.tag(1)
                calendarAccessPage.tag(2)
                calendarSelectionPage.tag(3)
                serverSettingsPage.tag(4)
                completionPage.tag(5)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .animation(.easeInOut(duration: 0.3), value: currentStep)
            .onChange(of: currentStep) { oldValue, newValue in
                if oldValue == 1 && newValue > 1 && !privacyAcknowledged {
                    currentStep = 1
                    highlightPrivacyButton = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        highlightPrivacyButton = false
                    }
                }
            }
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Circle()
                    .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(step == currentStep ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3), value: currentStep)
            }
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        WizardInfoPage(
            icon: "calendar.badge.clock",
            iconColor: .accentColor,
            title: "Welcome to CalMirror",
            description: "CalMirror syncs your iOS calendar events to a CalDAV server, keeping a read-only mirror of your schedule accessible from anywhere.\n\nYour events stay on your device — CalMirror simply reads them and pushes copies to the server you configure.",
            buttonTitle: "Let's Go"
        ) {
            withAnimation { currentStep = 1 }
        }
    }

    // MARK: - Page 2: Privacy Warning

    private var privacyPage: some View {
        WizardInfoPage(
            icon: "exclamationmark.shield",
            iconColor: .orange,
            title: "Your Privacy Matters",
            description: "Calendar events often contain private information — meeting details, locations, attendees, and personal notes.\n\nBy using CalMirror, you choose to forward this data to a third-party CalDAV server that you configure. Please make sure you trust the server you connect to.\n\nCalMirror never sends data anywhere else.",
            buttonTitle: "I Understand",
            highlightButton: $highlightPrivacyButton
        ) {
            privacyAcknowledged = true
            withAnimation { currentStep = 2 }
        }
    }

    // MARK: - Page 3: Calendar Access

    private var calendarAccessPage: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 24) {
                        Image(systemName: "calendar")
                            .font(.system(size: 72, weight: .light))
                            .foregroundStyle(.green.gradient)
                            .symbolRenderingMode(.multicolor)
                            .padding(.bottom, 8)

                        Text("Calendar Access")
                            .font(.largeTitle.weight(.bold))

                        Text("iOS requires **Full Access** permission to read your calendar events. This may sound like a lot, but it's the only way for apps to read event details.\n\nCalMirror **never** creates, modifies, or deletes any of your calendar events. The app is designed to be strictly read-only.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        if isCalendarDenied {
                            Label("Calendar access was denied. Please enable it in Settings.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)

                            #if os(iOS) || os(visionOS)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            #endif
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer()

                    VStack(spacing: 12) {
                        if hasCalendarAccess {
                            Label("Access Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.headline)
                                .transition(.opacity.combined(with: .scale))
                        }

                        Button {
                            if hasCalendarAccess {
                                withAnimation { currentStep = 3 }
                            } else {
                                Task { await requestCalendarAccess() }
                            }
                        } label: {
                            Text(hasCalendarAccess ? "Continue" : "Grant Access")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRequestingAccess)

                        if !hasCalendarAccess && !isCalendarDenied {
                            Button("Skip for Now") {
                                withAnimation { currentStep = 3 }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                }
                .frame(minHeight: geometry.size.height)
            }
        }
        .task {
            await checkCalendarAccess()
        }
    }

    // MARK: - Page 4: Calendar Selection

    private var calendarSelectionPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Choose Your Calendars")
                    .font(.title2.weight(.bold))
                Text("Select which calendars to sync")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            CalendarSelectionView(eventStore: eventStore, initialCalendars: initialCalendars)

            Button {
                withAnimation { currentStep = 4 }
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Page 5: Server Settings

    private var serverSettingsPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Connect Your Server")
                    .font(.title2.weight(.bold))
                Text("Configure your CalDAV destination")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            ServerSettingsView()

            Button {
                withAnimation { currentStep = 5 }
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Page 6: Completion

    private var completionPage: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 24) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 72, weight: .light))
                            .foregroundStyle(.green.gradient)
                            .symbolRenderingMode(.multicolor)
                            .padding(.bottom, 8)

                        Text("You're All Set!")
                            .font(.largeTitle.weight(.bold))

                        Text("Everything is configured. CalMirror will now keep your calendar synced to your server.\n\nYou can adjust all settings at any time from the main screen.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)

                    Spacer()

                    Button {
                        hasCompletedOnboarding = true
                    } label: {
                        Text("Start Using CalMirror")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                }
                .frame(minHeight: geometry.size.height)
            }
        }
    }

    // MARK: - Calendar Access Helpers

    private func checkCalendarAccess() async {
        let status = eventStore.authorizationStatus()
        hasCalendarAccess = status == .fullAccess
        isCalendarDenied = status == .denied || status == .restricted
    }

    private func requestCalendarAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }

        do {
            hasCalendarAccess = try await eventStore.requestAccess()
            if !hasCalendarAccess {
                isCalendarDenied = true
            }
        } catch {
            hasCalendarAccess = false
            isCalendarDenied = true
        }
    }
}

// MARK: - Reusable Info Page (Pages 1, 2)

private struct WizardInfoPage: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let buttonTitle: String
    var highlightButton: Binding<Bool>?
    let action: () -> Void

    private var isHighlighted: Bool {
        highlightButton?.wrappedValue ?? false
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer()

                        VStack(spacing: 24) {
                            Image(systemName: icon)
                                .font(.system(size: 72, weight: .light))
                                .foregroundStyle(iconColor.gradient)
                                .symbolRenderingMode(.multicolor)
                                .padding(.bottom, 8)

                            Text(title)
                                .font(.largeTitle.weight(.bold))

                            Text(description)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 32)

                        Spacer()

                        Button(action: action) {
                            Text(buttonTitle)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .scaleEffect(isHighlighted ? 1.15 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: isHighlighted)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 48)
                        .id("actionButton")
                    }
                    .frame(minHeight: geometry.size.height)
                }
                .onChange(of: isHighlighted) { _, highlighted in
                    if highlighted {
                        withAnimation {
                            scrollProxy.scrollTo("actionButton", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Onboarding") {
    WelcomeWizardView(
        hasCompletedOnboarding: .constant(false),
        eventStore: MockEventStore(authorizationStatus: .notDetermined)
    )
    .modelContainer(previewModelContainer())
}

#Preview("Access Granted") {
    WelcomeWizardView(
        hasCompletedOnboarding: .constant(false),
        eventStore: MockEventStore(),
        initialCalendars: PreviewData.calendars
    )
    .modelContainer(previewModelContainer(populate: true))
}

#Preview("No Calendars") {
    WelcomeWizardView(
        hasCompletedOnboarding: .constant(false),
        eventStore: MockEventStore()
    )
    .modelContainer(previewModelContainer())
}

#Preview("Access Denied") {
    WelcomeWizardView(
        hasCompletedOnboarding: .constant(false),
        eventStore: MockEventStore(authorizationStatus: .denied)
    )
    .modelContainer(previewModelContainer())
}

#Preview("Dark Mode") {
    WelcomeWizardView(
        hasCompletedOnboarding: .constant(false),
        eventStore: MockEventStore(),
        initialCalendars: PreviewData.calendars
    )
    .modelContainer(previewModelContainer(populate: true))
    .preferredColorScheme(.dark)
}
#endif
