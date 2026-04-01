import Foundation

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
            throw CalDAVError.invalidURL
        }
        guard !username.isEmpty, !password.isEmpty else {
            throw CalDAVError.missingCredentials
        }

        self.baseURL = url
        self.calendarPath = calendarPath
        self.username = username
        self.password = password

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Creates or updates an event on the CalDAV server.
    func putEvent(icsData: String, uid: String) async throws {
        let url = eventURL(for: uid)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        addAuthHeader(to: &request)
        request.httpBody = Data(icsData.utf8)

        let (_, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.invalidResponse
        }

        // 201 Created or 204 No Content are both success
        guard (200...299).contains(httpResponse.statusCode) else {
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
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuthHeader(to: &request)

        let (_, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.invalidResponse
        }

        // 204 No Content or 200 OK are success; 404 means already gone (also OK)
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
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

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CalDAVError.authenticationFailed
        }

        // 207 Multi-Status is the expected CalDAV response
        return (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207
    }

    // MARK: - Private Helpers

    private func eventURL(for uid: String) -> URL {
        let path = calendarPath.hasPrefix("/") ? calendarPath : "/\(calendarPath)"
        let fullPath = path.hasSuffix("/") ? "\(path)\(uid).ics" : "\(path)/\(uid).ics"
        return URL(string: baseURL.absoluteString + fullPath)!
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
            return try await session.data(for: request)
        } catch {
            throw CalDAVError.networkError(error)
        }
    }
}
