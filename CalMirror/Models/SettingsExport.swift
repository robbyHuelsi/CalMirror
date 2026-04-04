import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    static let calMirrorSettings = UTType(exportedAs: "de.huelsi.CalMirror.settings")
}

struct SettingsExport: Codable {
    var exportDate: Date
    var server: ServerExport?
    var calendars: [CalendarExport]

    struct ServerExport: Codable {
        var serverURL: String
        var username: String
        var calendarPath: String
        var syncIntervalMinutes: Int
        var isActive: Bool
    }

    struct CalendarExport: Codable {
        var calendarIdentifier: String
        var calendarName: String
        var isEnabled: Bool
        var isPrefixEnabled: Bool
        var customPrefix: String?
        var pastValue: Int
        var pastUnit: String
        var futureValue: Int
        var futureUnit: String
    }

    static func from(modelContext: ModelContext) throws -> SettingsExport {
        let serverConfigs = try modelContext.fetch(FetchDescriptor<ServerConfiguration>())
        let calendarConfigs = try modelContext.fetch(FetchDescriptor<CalendarSyncConfig>())

        let serverExport = serverConfigs.first.map { config in
            ServerExport(
                serverURL: config.serverURL,
                username: config.username,
                calendarPath: config.calendarPath,
                syncIntervalMinutes: config.syncIntervalMinutes,
                isActive: config.isActive
            )
        }

        let calendarExports = calendarConfigs.map { config in
            CalendarExport(
                calendarIdentifier: config.calendarIdentifier,
                calendarName: config.calendarName,
                isEnabled: config.isEnabled,
                isPrefixEnabled: config.isPrefixEnabled,
                customPrefix: config.customPrefix,
                pastValue: config.pastValue,
                pastUnit: config.pastUnit,
                futureValue: config.futureValue,
                futureUnit: config.futureUnit
            )
        }

        return SettingsExport(
            exportDate: Date(),
            server: serverExport,
            calendars: calendarExports
        )
    }

    func apply(to modelContext: ModelContext) throws {
        // Replace server configuration
        let existingServers = try modelContext.fetch(FetchDescriptor<ServerConfiguration>())
        for existing in existingServers {
            modelContext.delete(existing)
        }

        if let server {
            let config = ServerConfiguration(
                serverURL: server.serverURL,
                username: server.username,
                calendarPath: server.calendarPath,
                syncIntervalMinutes: server.syncIntervalMinutes,
                isActive: server.isActive
            )
            modelContext.insert(config)
        }

        // Replace calendar configurations
        let existingCalendars = try modelContext.fetch(FetchDescriptor<CalendarSyncConfig>())
        for existing in existingCalendars {
            modelContext.delete(existing)
        }

        for cal in calendars {
            let config = CalendarSyncConfig(
                calendarIdentifier: cal.calendarIdentifier,
                calendarName: cal.calendarName,
                isEnabled: cal.isEnabled,
                isPrefixEnabled: cal.isPrefixEnabled,
                customPrefix: cal.customPrefix,
                pastValue: cal.pastValue,
                pastUnit: cal.pastUnit,
                futureValue: cal.futureValue,
                futureUnit: cal.futureUnit
            )
            modelContext.insert(config)
        }

        try modelContext.save()
    }
}

struct SettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(export: SettingsExport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.data = try encoder.encode(export)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    func decode() throws -> SettingsExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SettingsExport.self, from: data)
    }
}
