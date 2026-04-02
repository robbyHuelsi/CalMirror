import Foundation

typealias ServerConfiguration = SchemaV1.ServerConfiguration

extension SchemaV1.ServerConfiguration {
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
