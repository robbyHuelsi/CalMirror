import Foundation
import SwiftData

@Model
final class ServerConfiguration {
    @Attribute(.unique) var id: String
    var serverURL: String
    var username: String
    var calendarPath: String
    var syncIntervalMinutes: Int
    var isActive: Bool
    var displayName: String

    init(
        serverURL: String = "",
        username: String = "",
        calendarPath: String = "/calendars/",
        syncIntervalMinutes: Int = 30,
        isActive: Bool = true,
        displayName: String = "CalDAV Server"
    ) {
        self.id = UUID().uuidString
        self.serverURL = serverURL
        self.username = username
        self.calendarPath = calendarPath
        self.syncIntervalMinutes = syncIntervalMinutes
        self.isActive = isActive
        self.displayName = displayName
    }

    /// The full URL to the calendar collection on the CalDAV server.
    var calendarCollectionURL: URL? {
        guard var base = URL(string: serverURL) else { return nil }
        let path = calendarPath.hasPrefix("/") ? calendarPath : "/\(calendarPath)"
        base.appendPathComponent(path)
        return base
    }

    /// Keychain service identifier for storing the password.
    var keychainServiceID: String {
        "com.calmirror.server.\(id)"
    }
}
