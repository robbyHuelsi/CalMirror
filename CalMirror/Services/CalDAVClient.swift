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
    func putEvent(icsData: String, uid: String) async throws {
        let url = eventURL(for: uid)
        logger.info("PUT \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
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
