import Foundation
import os.log

private let logger = Logger(subsystem: "de.huelsi.CalMirror", category: "CalDAV")

/// Errors that can occur during CalDAV operations.
enum CalDAVError: LocalizedError {
    case invalidURL
    case missingCredentials
    case authenticationFailed
    case serverError(statusCode: Int, message: String?)
    case networkError(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case .missingCredentials:
            return "Missing username or password."
        case .authenticationFailed:
            return "Authentication failed. Please check your credentials."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message ?? "Unknown error")"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server."
        }
    }
}

/// Metadata for a remote event fetched via CalDAV REPORT.
struct RemoteEventMetadata: Sendable {
    let uid: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

/// A CalDAV client that handles PUT, DELETE, and PROPFIND operations.
actor CalDAVClient {
    private let session: URLSession
    private let baseURL: URL
    private let calendarPath: String
    private let username: String
    private let password: String

    init(serverURL: String, calendarPath: String, username: String, password: String) throws {
        guard let url = URL(string: serverURL) else {
            logger.error("Invalid server URL: \(serverURL)")
            throw CalDAVError.invalidURL
        }
        guard !username.isEmpty, !password.isEmpty else {
            logger.error("Missing credentials (user=\(username), pw empty=\(password.isEmpty))")
            throw CalDAVError.missingCredentials
        }

        self.baseURL = url
        self.calendarPath = calendarPath
        self.username = username
        self.password = password
        logger.info("CalDAVClient init: baseURL=\(url.absoluteString), path=\(calendarPath), user=\(username)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Creates or updates an event on the CalDAV server.
    func putEvent(icsData: String, uid: String, isNew: Bool = true) async throws {
        let url = eventURL(for: uid)
        logger.info("PUT \(url.absoluteString) (isNew=\(isNew))")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if isNew {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        addAuthHeader(to: &request)
        request.httpBody = Data(icsData.utf8)
        logger.debug("PUT body (\(icsData.count) chars): \(String(icsData.prefix(200)))")

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("PUT \(uid): invalid response (not HTTP)")
            throw CalDAVError.invalidResponse
        }

        logger.info("PUT \(uid): HTTP \(httpResponse.statusCode)")

        // 201 Created or 204 No Content are both success
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            logger.error("PUT \(uid) failed: HTTP \(httpResponse.statusCode) — \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CalDAVError.authenticationFailed
            }
            throw CalDAVError.serverError(
                statusCode: httpResponse.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
    }

    /// Deletes an event from the CalDAV server.
    func deleteEvent(uid: String) async throws {
        let url = eventURL(for: uid)
        logger.info("DELETE \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuthHeader(to: &request)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("DELETE \(uid): invalid response (not HTTP)")
            throw CalDAVError.invalidResponse
        }

        logger.info("DELETE \(uid): HTTP \(httpResponse.statusCode)")

        // 204 No Content or 200 OK are success; 404 means already gone (also OK)
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            logger.error("DELETE \(uid) failed: HTTP \(httpResponse.statusCode) — \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CalDAVError.authenticationFailed
            }
            throw CalDAVError.serverError(
                statusCode: httpResponse.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
    }

    /// Tests the connection to the CalDAV server using PROPFIND.
    func testConnection() async throws -> Bool {
        var url = baseURL
        let path = calendarPath.hasPrefix("/") ? calendarPath : "/\(calendarPath)"
        if let combined = URL(string: url.absoluteString + path) {
            url = combined
        }
        logger.info("PROPFIND (testConnection) \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        let propfindBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
          </d:prop>
        </d:propfind>
        """
        request.httpBody = Data(propfindBody.utf8)

        let (_, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.invalidResponse
        }

        logger.info("PROPFIND testConnection: HTTP \(httpResponse.statusCode)")

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            logger.error("PROPFIND testConnection: auth failed (\(httpResponse.statusCode))")
            throw CalDAVError.authenticationFailed
        }

        // 207 Multi-Status is the expected CalDAV response
        let success = (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207
        logger.info("PROPFIND testConnection: success=\(success)")
        return success
    }

    // MARK: - Private Helpers

    /// Lists all event UIDs on the CalDAV server by performing a PROPFIND with Depth: 1.
    func listEventUIDs() async throws -> Set<String> {
        var url = baseURL
        let path = calendarPath.hasPrefix("/") ? calendarPath : "/\(calendarPath)"
        if let combined = URL(string: url.absoluteString + path) {
            url = combined
        }
        logger.info("PROPFIND (listEventUIDs) \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        let propfindBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:getetag/>
          </d:prop>
        </d:propfind>
        """
        request.httpBody = Data(propfindBody.utf8)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.invalidResponse
        }

        logger.info("PROPFIND listEventUIDs: HTTP \(httpResponse.statusCode)")

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CalDAVError.authenticationFailed
        }

        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207 else {
            throw CalDAVError.serverError(
                statusCode: httpResponse.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        let uids = Self.extractUIDsFromPropfindResponse(body)
        logger.info("PROPFIND listEventUIDs: found \(uids.count) UIDs")
        return uids
    }

    /// Fetches metadata (UID, title, dates) for all events on the CalDAV server using a REPORT calendar-query.
    func fetchRemoteEventMetadata() async throws -> [RemoteEventMetadata] {
        var url = baseURL
        let path = calendarPath.hasPrefix("/") ? calendarPath : "/\(calendarPath)"
        if let combined = URL(string: url.absoluteString + path) {
            url = combined
        }
        logger.info("REPORT (fetchRemoteEventMetadata) \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "REPORT"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        let reportBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag/>
            <c:calendar-data>
              <c:comp name="VCALENDAR">
                <c:comp name="VEVENT">
                  <c:prop name="UID"/>
                  <c:prop name="SUMMARY"/>
                  <c:prop name="DTSTART"/>
                  <c:prop name="DTEND"/>
                </c:comp>
              </c:comp>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT"/>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """
        request.httpBody = Data(reportBody.utf8)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.invalidResponse
        }

        logger.info("REPORT fetchRemoteEventMetadata: HTTP \(httpResponse.statusCode)")

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CalDAVError.authenticationFailed
        }

        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207 else {
            throw CalDAVError.serverError(
                statusCode: httpResponse.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        let calendarDataFragments = CalendarDataParser.parseCalendarData(from: body)
        var results: [RemoteEventMetadata] = []
        for ics in calendarDataFragments {
            if let meta = Self.parseICSFragment(ics) {
                results.append(meta)
            }
        }
        logger.info("REPORT fetchRemoteEventMetadata: parsed \(results.count) events")
        return results
    }

    /// Parses a minimal ICS fragment to extract event metadata.
    private static func parseICSFragment(_ ics: String) -> RemoteEventMetadata? {
        var uid: String?
        var summary: String?
        var dtstart: String?
        var dtend: String?

        for line in ics.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("UID:") {
                uid = String(trimmed.dropFirst(4))
            } else if trimmed.hasPrefix("SUMMARY:") {
                summary = String(trimmed.dropFirst(8))
            } else if trimmed.hasPrefix("DTSTART") {
                dtstart = Self.extractDateValue(from: trimmed)
            } else if trimmed.hasPrefix("DTEND") {
                dtend = Self.extractDateValue(from: trimmed)
            }
        }

        guard let uid, !uid.isEmpty else { return nil }

        let isAllDay: Bool
        let startDate: Date
        let endDate: Date

        if let dtstart, let parsed = Self.parseICSDate(dtstart) {
            startDate = parsed.date
            isAllDay = parsed.isAllDay
        } else {
            startDate = .distantPast
            isAllDay = false
        }

        if let dtend, let parsed = Self.parseICSDate(dtend) {
            endDate = parsed.date
        } else {
            endDate = startDate
        }

        return RemoteEventMetadata(
            uid: uid,
            title: summary ?? uid,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay
        )
    }

    /// Extracts the date value from an ICS property line like "DTSTART;VALUE=DATE:20260404" or "DTSTART:20260404T100000Z".
    private static func extractDateValue(from line: String) -> String? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Parses an ICS date string into a Date, returning whether it's an all-day event.
    private static func parseICSDate(_ value: String) -> (date: Date, isAllDay: Bool)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // UTC format: 20260404T100000Z
        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: value) {
                return (date, false)
            }
        }

        // Local datetime: 20260404T100000
        if value.contains("T") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = .current
            if let date = formatter.date(from: value) {
                return (date, false)
            }
        }

        // All-day date: 20260404
        if value.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            if let date = formatter.date(from: value) {
                return (date, true)
            }
        }

        return nil
    }

    /// Parses a PROPFIND Depth:1 response to extract UIDs from href elements ending in .ics.
    private static func extractUIDsFromPropfindResponse(_ xml: String) -> Set<String> {
        let parser = HrefParser()
        parser.parse(xml: xml)
        var uids = Set<String>()
        for href in parser.hrefs {
            // Extract UID from href like "/calendars/user/calendar/UUID.ics"
            guard href.hasSuffix(".ics") else { continue }
            let filename = (href as NSString).lastPathComponent
            let uid = String(filename.dropLast(4)) // Remove ".ics"
            if !uid.isEmpty {
                uids.insert(uid)
            }
        }
        return uids
    }

    private func eventURL(for uid: String) -> URL {
        let path = calendarPath.hasPrefix("/") ? calendarPath : "/\(calendarPath)"
        let fullPath = path.hasSuffix("/") ? "\(path)\(uid).ics" : "\(path)/\(uid).ics"
        let url = URL(string: baseURL.absoluteString + fullPath)!
        logger.debug("eventURL: \(url.absoluteString)")
        return url
    }

    private func addAuthHeader(to request: inout URLRequest) {
        let credentials = "\(username):\(password)"
        if let data = credentials.data(using: .utf8) {
            let base64 = data.base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response)
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw CalDAVError.networkError(error)
        }
    }
}

// MARK: - XML Parser for PROPFIND href extraction

private class HrefParser: NSObject, XMLParserDelegate {
    var hrefs: [String] = []
    private var currentElement = ""
    private var currentText = ""

    func parse(xml: String) {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName.hasSuffix("href") {
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement.hasSuffix("href") {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName.hasSuffix("href") {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                hrefs.append(trimmed)
            }
        }
        currentElement = ""
    }
}

// MARK: - XML Parser for REPORT calendar-data extraction

private class CalendarDataParser: NSObject, XMLParserDelegate {
    private var fragments: [String] = []
    private var currentElement = ""
    private var currentText = ""
    private var insideCalendarData = false

    static func parseCalendarData(from xml: String) -> [String] {
        let parser = CalendarDataParser()
        let xmlParser = XMLParser(data: Data(xml.utf8))
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.fragments
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName.hasSuffix("calendar-data") {
            insideCalendarData = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideCalendarData {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName.hasSuffix("calendar-data") {
            insideCalendarData = false
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                fragments.append(trimmed)
            }
        }
        currentElement = ""
    }
}
