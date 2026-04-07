import SwiftUI
import SwiftData

struct ServerSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var serverConfigs: [ServerConfiguration]

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var calendarPath = "/calendars/"
    @State private var syncInterval = 30

    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var isLoading = true

    private enum TestResult {
        case success
        case failure(String)
    }

    private let syncIntervalOptions = [15, 30, 60, 120]
    private let headerView: AnyView?
    private let footerView: AnyView?
    private let showTestButton: Bool
    private let interactiveFooterBuilder: ((_ isFormValid: Bool, _ performTest: @escaping () async throws -> Bool) -> AnyView)?

    init() {
        self.headerView = nil
        self.footerView = nil
        self.showTestButton = true
        self.interactiveFooterBuilder = nil
    }

    init<H: View, F: View>(@ViewBuilder header: () -> H, @ViewBuilder footer: () -> F) {
        self.headerView = AnyView(header())
        self.footerView = AnyView(footer())
        self.showTestButton = true
        self.interactiveFooterBuilder = nil
    }

    init<H: View, F: View>(
        showTestButton: Bool = true,
        @ViewBuilder header: () -> H,
        @ViewBuilder interactiveFooter: @escaping (_ isFormValid: Bool, _ performTest: @escaping () async throws -> Bool) -> F
    ) {
        self.headerView = AnyView(header())
        self.footerView = nil
        self.showTestButton = showTestButton
        self.interactiveFooterBuilder = { isFormValid, performTest in
            AnyView(interactiveFooter(isFormValid, performTest))
        }
    }

    var body: some View {
        Form {
            if let headerView {
                Section {
                    headerView
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section("Server") {
                TextField("Server URL", text: $serverURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()

            }

            Section("Authentication") {
                TextField("Username", text: $username)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
            }

            Section("Calendar Path") {
                TextField("Path on Server", text: $calendarPath)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()

                Text("e.g. /remote.php/dav/calendars/user/calmirror/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sync Interval") {
                Picker("Fallback Interval", selection: $syncInterval) {
                    ForEach(syncIntervalOptions, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
            }

            if showTestButton {
                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || serverURL.isEmpty || username.isEmpty || password.isEmpty)

                    if let testResult {
                        switch testResult {
                        case .success:
                            Label("Connection successful", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if let footerView {
                Section {
                    footerView
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let interactiveFooterBuilder {
                let isFormValid = !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
                Section {
                    interactiveFooterBuilder(isFormValid, performTestConnection)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

        }
        .navigationTitle("Server Settings")
        .scrollContentBackground(headerView != nil ? .hidden : .automatic)
        .onAppear(perform: loadExisting)
        .onChange(of: serverURL) { saveConfiguration() }
        .onChange(of: username) { saveConfiguration() }
        .onChange(of: password) { saveConfiguration() }
        .onChange(of: calendarPath) { saveConfiguration() }
        .onChange(of: syncInterval) { saveConfiguration() }
    }

    private func loadExisting() {
        guard let existing = serverConfigs.first else {
            DispatchQueue.main.async { isLoading = false }
            return
        }
        serverURL = existing.serverURL
        username = existing.username
        calendarPath = existing.calendarPath
        syncInterval = existing.syncIntervalMinutes
        if let pw = KeychainHelper.load(
            service: existing.keychainServiceID,
            account: existing.username
        ) {
            password = pw
        }
        // Defer to next run loop iteration so isLoading is still true
        // when SwiftUI fires the batched onChange handlers above
        DispatchQueue.main.async { isLoading = false }
    }

    private func saveConfiguration() {
        guard !isLoading else { return }
        let config: ServerConfiguration
        if let existing = serverConfigs.first {
            config = existing
            // If username changed, delete old keychain entry
            if existing.username != username {
                KeychainHelper.delete(
                    service: existing.keychainServiceID,
                    account: existing.username
                )
            }
        } else {
            config = ServerConfiguration()
            modelContext.insert(config)
        }

        config.serverURL = serverURL
        config.username = username
        config.calendarPath = calendarPath
        config.syncIntervalMinutes = syncInterval
        config.isActive = true

        if !password.isEmpty {
            try? KeychainHelper.save(
                password: password,
                service: config.keychainServiceID,
                account: username
            )
        }

        try? modelContext.save()
    }

    func performTestConnection() async throws -> Bool {
        let client = try CalDAVClient(
            serverURL: serverURL,
            calendarPath: calendarPath,
            username: username,
            password: password
        )
        let success = try await client.testConnection()
        if !success {
            throw CalDAVError.invalidResponse
        }
        return true
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        do {
            _ = try await performTestConnection()
            testResult = .success
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Empty") {
    NavigationStack {
        ServerSettingsView()
    }
    .modelContainer(previewModelContainer())
}

#Preview("Configured") {
    NavigationStack {
        ServerSettingsView()
    }
    .modelContainer(previewModelContainer(populate: true))
}

#Preview("Dark Mode") {
    NavigationStack {
        ServerSettingsView()
    }
    .modelContainer(previewModelContainer(populate: true))
    .preferredColorScheme(.dark)
}
#endif
