import Foundation

final class KilometrikisaClient: NSObject, URLSessionTaskDelegate {
    private let baseURL = URL(string: "https://www.kilometrikisa.fi")!
    private let cookieStorage = HTTPCookieStorage()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Kulumeter iOS"
        ]
        return URLSession(configuration: configuration)
    }()
    private lazy var loginSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Kulumeter iOS"
        ]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func login(username: String, password: String) async throws -> KilometrikisaSession {
        let loginURL = baseURL.appending(path: "/accounts/login/")
        let (loginPageData, initialResponse) = try await session.data(from: loginURL)
        guard let initialHTTPResponse = initialResponse as? HTTPURLResponse else {
            throw KilometrikisaError.invalidResponse
        }

        guard let csrfCookieToken = cookie(named: "csrftoken", in: initialHTTPResponse) else {
            throw KilometrikisaError.missingCSRFToken
        }
        let loginPageHTML = String(decoding: loginPageData, as: UTF8.self)
        let csrfFormToken = Self.parseCSRFToken(from: loginPageHTML) ?? csrfCookieToken

        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue(loginURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("csrftoken=\(csrfCookieToken)", forHTTPHeaderField: "Cookie")
        request.httpBody = formBody([
            "username": username,
            "password": password,
            "csrfmiddlewaretoken": csrfFormToken,
            "next": "/accounts/index/"
        ])

        let (responseData, response) = try await loginSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KilometrikisaError.invalidResponse
        }

        let updatedCSRFToken = storedCookie(named: "csrftoken") ?? cookie(named: "csrftoken", in: httpResponse) ?? csrfCookieToken
        guard let sessionID = storedCookie(named: "sessionid") ?? cookie(named: "sessionid", in: httpResponse) else {
            if httpResponse.statusCode == 200,
               String(decoding: responseData, as: UTF8.self).contains(#"name="password""#) {
                throw KilometrikisaError.loginFailed
            }
            throw KilometrikisaError.loginFailed
        }

        return KilometrikisaSession(csrfToken: updatedCSRFToken, sessionID: sessionID)
    }

    func upload(_ ride: DailyRide, contestID: String, session: KilometrikisaSession) async throws {
        try await updateDistance(ride, contestID: contestID, session: session)
        try await updateMinutes(ride, contestID: contestID, session: session)
    }

    func fetchLoggedDates(contestID: String, from startDate: Date, to endDate: Date, session: KilometrikisaSession) async throws -> Set<String> {
        var components = URLComponents(url: baseURL.appending(path: "/contest/log_list_json/\(contestID)/"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: "\(Int(startDate.timeIntervalSince1970))"),
            URLQueryItem(name: "end", value: "\(Int(endDate.timeIntervalSince1970))"),
            URLQueryItem(name: "_", value: "\(Int(Date().timeIntervalSince1970 * 1000))")
        ]

        guard let url = components?.url else {
            throw KilometrikisaError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(baseURL.appending(path: "/contest/log/").absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("csrftoken=\(session.csrfToken); sessionid=\(session.sessionID);", forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KilometrikisaError.invalidResponse
        }
        guard httpResponse.statusCode != 403 else {
            throw KilometrikisaError.sessionExpired
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            let body = String(decoding: data.prefix(240), as: UTF8.self)
            throw KilometrikisaError.requestFailed(httpResponse.statusCode, body)
        }

        let body = String(decoding: data, as: UTF8.self)
        if body.contains(#"name="password""#) || body.contains(#"id="id_password""#) {
            throw KilometrikisaError.sessionExpired
        }

        return Self.parseLoggedDates(from: data)
    }

    func discoverContestID(session: KilometrikisaSession) async throws -> String {
        let url = baseURL.appending(path: "/contest/log/")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("csrftoken=\(session.csrfToken); sessionid=\(session.sessionID);", forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KilometrikisaError.invalidResponse
        }
        guard httpResponse.statusCode != 403 else {
            throw KilometrikisaError.sessionExpired
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            let body = String(decoding: data.prefix(240), as: UTF8.self)
            throw KilometrikisaError.requestFailed(httpResponse.statusCode, body)
        }

        let html = String(decoding: data, as: UTF8.self)
        guard let contestID = Self.parseContestID(from: html) else {
            return try await discoverContestIDFromAccountPage(session: session)
        }
        return contestID
    }

    private func discoverContestIDFromAccountPage(session: KilometrikisaSession) async throws -> String {
        let url = baseURL.appending(path: "/accounts/index/")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("csrftoken=\(session.csrfToken); sessionid=\(session.sessionID);", forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KilometrikisaError.invalidResponse
        }
        guard httpResponse.statusCode != 403 else {
            throw KilometrikisaError.sessionExpired
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            let body = String(decoding: data.prefix(240), as: UTF8.self)
            throw KilometrikisaError.requestFailed(httpResponse.statusCode, body)
        }

        let html = String(decoding: data, as: UTF8.self)
        guard let contestID = Self.parseContestID(from: html) else {
            throw KilometrikisaError.contestIDNotFound
        }
        return contestID
    }

    private func updateDistance(_ ride: DailyRide, contestID: String, session: KilometrikisaSession) async throws {
        let url = baseURL.appending(path: "/contest/log-save/")
        var request = authenticatedPostRequest(url: url, refererPath: "/contest/log/", session: session)
        let roundedDistance = (ride.distanceKilometers * 100).rounded() / 100
        let dateString = Self.kilometrikisaDateString(for: ride.date)
        request.httpBody = formBody([
            "contest_id": contestID,
            "km_amount": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), roundedDistance),
            "is_electric": ride.isElectric ? "1" : "0",
            "km_date": dateString,
            "csrfmiddlewaretoken": session.csrfToken
        ])
        try await submit(request)
    }

    private func updateMinutes(_ ride: DailyRide, contestID: String, session: KilometrikisaSession) async throws {
        let url = baseURL.appending(path: "/contest/minute-log-save/")
        var request = authenticatedPostRequest(url: url, refererPath: "/contest/log/", session: session)
        let totalSeconds = Int(ride.durationSeconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let dateString = Self.kilometrikisaDateString(for: ride.date)
        request.httpBody = formBody([
            "contest_id": contestID,
            "hours": "\(hours)",
            "minutes": "\(minutes)",
            "is_electric": ride.isElectric ? "1" : "0",
            "date": dateString,
            "csrfmiddlewaretoken": session.csrfToken
        ])
        try await submit(request)
    }

    nonisolated private static func kilometrikisaDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func authenticatedPostRequest(url: URL, refererPath: String, session: KilometrikisaSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(baseURL.appending(path: refererPath).absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("csrftoken=\(session.csrfToken); sessionid=\(session.sessionID);", forHTTPHeaderField: "Cookie")
        return request
    }

    private func submit(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KilometrikisaError.invalidResponse
        }
        guard httpResponse.statusCode != 403 else {
            throw KilometrikisaError.sessionExpired
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            let body = String(decoding: data.prefix(240), as: UTF8.self)
            throw KilometrikisaError.requestFailed(httpResponse.statusCode, body)
        }
    }

    private func cookie(named name: String, in response: HTTPURLResponse) -> String? {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else {
                return
            }
            result[key] = "\(item.value)"
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: baseURL)
        return cookies.first { $0.name == name }?.value
    }

    private func storedCookie(named name: String) -> String? {
        cookieStorage
            .cookies?
            .first { $0.name == name && $0.domain.contains("kilometrikisa.fi") }?
            .value
    }

    private func formBody(_ fields: [String: String]) -> Data {
        fields
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func parseContestID(from html: String) -> String? {
        let patterns = [
            #"<input[^>]+name=["']contest_id["'][^>]+value=["']([0-9]+)["']"#,
            #"<input[^>]+value=["']([0-9]+)["'][^>]+name=["']contest_id["']"#,
            #"/contest/log_list_json/([0-9]+)/"#,
            #"contest_id=([0-9]+)"#,
            #"/contest/log/\?contest_id=([0-9]+)"#,
            #"/contests/[^"']+/log/([0-9]+)"#,
            #"data-contest-id=["']([0-9]+)["']"#,
            #"contestId["']?\s*[:=]\s*["']?([0-9]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let contestRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            return String(html[contestRange])
        }

        return nil
    }

    static func parseCSRFToken(from html: String) -> String? {
        let patterns = [
            #"<input[^>]+name=["']csrfmiddlewaretoken["'][^>]+value=["']([^"']+)["']"#,
            #"<input[^>]+value=["']([^"']+)["'][^>]+name=["']csrfmiddlewaretoken["']"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            return String(html[tokenRange])
        }

        return nil
    }

    static func parseLoggedDates(from data: Data) -> Set<String> {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return parseLoggedDates(fromJSONObject: json)
        }

        let text = String(decoding: data, as: UTF8.self)
        return parseLoggedDates(fromText: text)
    }

    private static func parseLoggedDates(fromJSONObject object: Any) -> Set<String> {
        var dates = Set<String>()

        if let string = object as? String {
            dates.formUnion(parseLoggedDates(fromText: string))
        } else if let array = object as? [Any] {
            for item in array {
                dates.formUnion(parseLoggedDates(fromJSONObject: item))
            }
        } else if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if key.lowercased().contains("date") || key.lowercased() == "start" || key.lowercased() == "end" {
                    dates.formUnion(parseLoggedDates(fromJSONObject: value))
                } else if let nested = value as? [Any] {
                    dates.formUnion(parseLoggedDates(fromJSONObject: nested))
                } else if let nested = value as? [String: Any] {
                    dates.formUnion(parseLoggedDates(fromJSONObject: nested))
                }
            }
        }

        return dates
    }

    private static func parseLoggedDates(fromText text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\b([0-9]{4}-[0-9]{2}-[0-9]{2})\b"#) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let dateRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[dateRange])
        })
    }
}

struct KilometrikisaSession: Equatable {
    let csrfToken: String
    let sessionID: String
}

enum KilometrikisaError: LocalizedError {
    case invalidResponse
    case missingCSRFToken
    case loginFailed
    case sessionExpired
    case contestIDNotFound
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Kilometrikisa returned an invalid response."
        case .missingCSRFToken:
            return "Could not read the Kilometrikisa login token."
        case .loginFailed:
            return "Kilometrikisa login failed. Check the username and password."
        case .sessionExpired:
            return "Kilometrikisa rejected the upload because the session expired."
        case .contestIDNotFound:
            return "Could not find an active Kilometrikisa contest ID on the log page."
        case .requestFailed(let status, let body):
            return "Kilometrikisa request failed with HTTP \(status). \(body)"
        }
    }
}
