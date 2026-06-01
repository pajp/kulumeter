import Foundation
import os

final class KilometrikisaClient: NSObject, URLSessionTaskDelegate {
    private static let logger = Logger(subsystem: "nu.dll.kulumeter", category: "KilometrikisaClient")

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

    func fetchTeamRanking(session: KilometrikisaSession, currentUsername: String) async throws -> TeamRanking {
        let teamPath = try await discoverTeamPath(session: session)
        Self.logger.info("Loading Kilometrikisa team ranking from \(teamPath, privacy: .public)")
        let data = try await fetchAuthenticated(path: teamPath, refererPath: "/accounts/index/", session: session)
        let html = String(decoding: data, as: UTF8.self)
        Self.logger.info("Fetched team page \(teamPath, privacy: .public), \(data.count, privacy: .public) bytes")
        guard let ranking = Self.parseTeamRanking(from: html, path: teamPath, currentUsername: currentUsername) else {
            Self.logger.error("Could not parse team ranking from \(teamPath, privacy: .public)")
            throw KilometrikisaError.teamRankingNotFound
        }
        Self.logger.info("Parsed \(ranking.rows.count, privacy: .public) team ranking rows for \(ranking.name, privacy: .public)")
        return ranking
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

    private func discoverTeamPath(session: KilometrikisaSession) async throws -> String {
        let candidatePages = [
            "/accounts/index/",
            "/accounts/profile/",
            "/contest/log/"
        ]

        for path in candidatePages {
            Self.logger.info("Looking for Kilometrikisa team link on \(path, privacy: .public)")
            let data = try await fetchAuthenticated(path: path, refererPath: "/accounts/index/", session: session)
            let html = String(decoding: data, as: UTF8.self)
            if let teamPath = Self.parseTeamPath(from: html) {
                Self.logger.info("Found team path \(teamPath, privacy: .public) on \(path, privacy: .public)")
                return teamPath
            }
            if let profilePath = Self.parseProfilePath(from: html) {
                Self.logger.info("Found profile path \(profilePath, privacy: .public) on \(path, privacy: .public)")
                let profileData = try await fetchAuthenticated(path: profilePath, refererPath: path, session: session)
                let profileHTML = String(decoding: profileData, as: UTF8.self)
                if let teamPath = Self.parseTeamPath(from: profileHTML) {
                    Self.logger.info("Found team path \(teamPath, privacy: .public) on profile \(profilePath, privacy: .public)")
                    return teamPath
                }
            }
        }

        Self.logger.error("No Kilometrikisa team path found on account/profile/log pages")
        throw KilometrikisaError.teamNotFound
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

    private func fetchAuthenticated(path: String, refererPath: String, session: KilometrikisaSession) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              let refererURL = URL(string: refererPath, relativeTo: baseURL)?.absoluteURL else {
            throw KilometrikisaError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("csrftoken=\(session.csrfToken); sessionid=\(session.sessionID);", forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KilometrikisaError.invalidResponse
        }
        Self.logger.info("GET \(path, privacy: .public) returned HTTP \(httpResponse.statusCode, privacy: .public), \(data.count, privacy: .public) bytes")
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

        return data
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

    static func parseTeamPath(from html: String) -> String? {
        let patterns = [
            #"href\s*=\s*["'](/teams/[^"']+/)["']"#,
            #"href\s*=\s*["'](https://www\.kilometrikisa\.fi/teams/[^"']+/)["']"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let pathRange = Range(match.range(at: 1), in: html) else {
                    continue
                }

                let value = String(html[pathRange])
                let path: String
                if value.hasPrefix("/") {
                    path = value
                } else if let url = URL(string: value), let urlPath = url.path.nonEmptyPath {
                    path = urlPath
                } else {
                    path = value
                }

                guard isActualTeamPath(path) else {
                    logger.info("Ignoring non-team Kilometrikisa teams path \(path, privacy: .public)")
                    continue
                }
                return path
            }
        }

        return nil
    }

    private static func isActualTeamPath(_ path: String) -> Bool {
        let normalized = path.lowercased()
        guard normalized.hasPrefix("/teams/") else {
            return false
        }

        let reservedPaths: Set<String> = [
            "/teams/register/",
            "/teams/create/",
            "/teams/favorites/",
            "/teams/join/",
            "/teams/search/",
            "/teams/",
        ]
        if reservedPaths.contains(normalized) {
            return false
        }

        return normalized.split(separator: "/").count == 2
    }

    static func parseProfilePath(from html: String) -> String? {
        let patterns = [
            #"href\s*=\s*["'](/accounts/profile/[^"']*)["']"#,
            #"href\s*=\s*["'](/profiles/[^"']+/)["']"#,
            #"href\s*=\s*["'](/users/[^"']+/)["']"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            return String(html[pathRange])
        }

        return nil
    }

    static func parseTeamRanking(from html: String, path: String, currentUsername: String? = nil) -> TeamRanking? {
        let tableHTML = extractKilometrikisaRiderTable(from: html)
        let rows = parseTeamRankingRows(from: tableHTML, currentUsername: currentUsername)
        logger.info("Team ranking parse for \(path, privacy: .public): \(rows.count, privacy: .public) rows")
        guard !rows.isEmpty else {
            let preview = stripHTML(String(tableHTML.prefix(800)))
            logger.error("Team ranking parse found no rows. Preview: \(preview, privacy: .public)")
            return nil
        }

        return TeamRanking(
            name: parseTeamName(from: html) ?? teamNameFromPath(path),
            path: path,
            rows: rows
        )
    }

    private static func extractKilometrikisaRiderTable(from html: String) -> String {
        guard let tableRegex = try? NSRegularExpression(pattern: #"<table\b[\s\S]*?</table>"#, options: [.caseInsensitive]) else {
            return html
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let tables = tableRegex.matches(in: html, range: range).compactMap { match -> String? in
            guard let tableRange = Range(match.range, in: html) else {
                return nil
            }
            return String(html[tableRange])
        }

        logger.info("Found \(tables.count, privacy: .public) table elements on team page")
        if let riderTable = tables.first(where: { table in
            let normalized = stripHTML(table).lowercased()
            return normalized.contains("km yht") && (normalized.contains("ajopäivät") || normalized.contains("ajopaivat"))
        }) {
            let preview = stripHTML(String(riderTable.prefix(800)))
            logger.info("Selected rider table by header. Preview: \(preview, privacy: .public)")
            return riderTable
        }

        if let tableWithRows = tables.max(by: {
            parseTeamRankingRows(from: $0, currentUsername: nil).count < parseTeamRankingRows(from: $1, currentUsername: nil).count
        }),
           !parseTeamRankingRows(from: tableWithRows, currentUsername: nil).isEmpty {
            let preview = stripHTML(String(tableWithRows.prefix(800)))
            logger.info("Selected rider table by parseable rows. Preview: \(preview, privacy: .public)")
            return tableWithRows
        }

        logger.error("No rider table recognized; falling back to full HTML")
        return html
    }

    private static func parseTeamRankingRows(from html: String, currentUsername: String?) -> [TeamRankingRow] {
        guard let rowRegex = try? NSRegularExpression(pattern: #"<tr\b([^>]*)>([\s\S]*?)</tr>"#, options: [.caseInsensitive]),
              let cellRegex = try? NSRegularExpression(pattern: #"<t[dh]\b[^>]*>([\s\S]*?)</t[dh]>"#, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return rowRegex.matches(in: html, range: range).compactMap { rowMatch in
            guard rowMatch.numberOfRanges > 2,
                  let attributesRange = Range(rowMatch.range(at: 1), in: html),
                  let cellsRange = Range(rowMatch.range(at: 2), in: html) else {
                return nil
            }

            let attributes = String(html[attributesRange])
            let rowHTML = String(html[cellsRange])
            let cellRange = NSRange(rowHTML.startIndex..<rowHTML.endIndex, in: rowHTML)
            let cells = cellRegex.matches(in: rowHTML, range: cellRange).compactMap { cellMatch -> String? in
                guard cellMatch.numberOfRanges > 1,
                      let contentRange = Range(cellMatch.range(at: 1), in: rowHTML) else {
                    return nil
                }
                return stripHTML(String(rowHTML[contentRange]))
            }

            guard cells.count >= 6,
                  let rank = firstInteger(in: cells[0]),
                  let rideDays = firstInteger(in: cells[5]) else {
                return nil
            }

            return TeamRankingRow(
                rank: rank,
                name: cells[1],
                totalKilometers: cells[2],
                muscleKilometers: cells[3],
                electricKilometers: cells[4],
                rideDays: rideDays,
                isCurrentUser: containsCurrentUserMarker(in: attributes + " " + rowHTML) || isCurrentUserName(cells[1], currentUsername: currentUsername)
            )
        }
    }

    private static func isCurrentUserName(_ riderName: String, currentUsername: String?) -> Bool {
        guard let currentUsername else {
            return false
        }

        let normalizedRiderName = normalizeUsername(riderName)
        let normalizedCurrentUsername = normalizeUsername(currentUsername)
        guard !normalizedRiderName.isEmpty, !normalizedCurrentUsername.isEmpty else {
            return false
        }

        return normalizedRiderName == normalizedCurrentUsername
    }

    private static func normalizeUsername(_ value: String) -> String {
        stripHTML(value)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func containsCurrentUserMarker(in html: String) -> Bool {
        let normalized = html.lowercased()
        let markers = [
            "current",
            "highlight",
            "selected",
            "active",
            "success",
            "warning",
            "own-row",
            "own_user",
            "own-user",
            "background-color",
            "background:",
            "#ffff",
            "yellow"
        ]

        return markers.contains { normalized.contains($0) }
    }

    private static func parseTeamName(from html: String) -> String? {
        let patterns = [
            #"<h1[^>]*>([\s\S]*?)</h1>"#,
            #"<h2[^>]*>([\s\S]*?)</h2>"#,
            #"<title[^>]*>([\s\S]*?)</title>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: html) else {
                    continue
                }
                if let name = cleanTeamNameCandidate(String(html[nameRange])) {
                    return name
                }
            }
        }

        return nil
    }

    private static func cleanTeamNameCandidate(_ html: String) -> String? {
        var name = stripHTML(html)
            .replacingOccurrences(of: #"(?i)\bjoukkue\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bteam\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–|")))

        if let separatorRange = name.range(of: #"(?i)\s+[|–-]\s+kilometrikisa\b.*$"#, options: .regularExpression) {
            name.removeSubrange(separatorRange)
            name = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–|")))
        }

        guard !name.isEmpty else {
            return nil
        }

        let genericNames = [
            "kilometrikisa",
            "minuuttikisa",
            "tietoa",
            "tulokset"
        ]
        guard !genericNames.contains(name.lowercased()) else {
            return nil
        }

        return name
    }

    private static func teamNameFromPath(_ path: String) -> String {
        guard let slug = path.split(separator: "/").last else {
            return "Team"
        }

        return slug
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: "-")
    }

    private static func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeHTMLEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstInteger(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]+"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return Int(text[matchRange])
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&auml;", with: "ä")
            .replacingOccurrences(of: "&ouml;", with: "ö")
            .replacingOccurrences(of: "&Auml;", with: "Ä")
            .replacingOccurrences(of: "&Ouml;", with: "Ö")
        result = result.replacingOccurrences(of: "&#228;", with: "ä")
        result = result.replacingOccurrences(of: "&#246;", with: "ö")
        result = result.replacingOccurrences(of: "&#196;", with: "Ä")
        result = result.replacingOccurrences(of: "&#214;", with: "Ö")
        return result
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

        if let array = object as? [Any] {
            for item in array {
                dates.formUnion(parseLoggedDates(fromJSONObject: item))
            }
        } else if let dictionary = object as? [String: Any] {
            if dictionary.representsLoggedRide {
                dates.formUnion(loggedDates(fromEntry: dictionary))
            }

            for (key, value) in dictionary {
                if key.lowercased().contains("date") || key.lowercased() == "start" || key.lowercased() == "end" {
                    continue
                }

                if let nested = value as? [Any] {
                    dates.formUnion(parseLoggedDates(fromJSONObject: nested))
                } else if let nested = value as? [String: Any] {
                    dates.formUnion(parseLoggedDates(fromJSONObject: nested))
                }
            }
        }

        return dates
    }

    private static func loggedDates(fromEntry entry: [String: Any]) -> Set<String> {
        var dates = Set<String>()

        for (key, value) in entry {
            let normalizedKey = key.lowercased()
            guard normalizedKey.contains("date") || normalizedKey == "start" else {
                continue
            }

            dates.formUnion(parseLoggedDates(fromJSONObjectTextValue: value))
        }

        return dates
    }

    private static func parseLoggedDates(fromJSONObjectTextValue value: Any) -> Set<String> {
        if let string = value as? String {
            return parseLoggedDates(fromText: string)
        }
        if let number = value as? NSNumber {
            return parseLoggedDates(fromText: "\(number)")
        }
        return []
    }

    private static func parseLoggedDates(fromText text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\b([0-9]{4}-[0-9]{2}-[0-9]{2})(?:\b|T)"#) else {
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

private extension Dictionary where Key == String, Value == Any {
    var representsLoggedRide: Bool {
        containsPositiveNumericLogValue ||
            Self.containsPositiveTextLogValue(in: Array(values)) ||
            containsPositivePlainAmountValue
    }

    private var containsPositiveNumericLogValue: Bool {
        contains { key, value in
            let normalizedKey = key.lowercased()
            guard normalizedKey.contains("km") ||
                    normalizedKey.contains("distance") ||
                    normalizedKey.contains("amount") ||
                    normalizedKey == "hours" ||
                    normalizedKey == "minutes" else {
                return false
            }

            return Self.positiveDouble(from: value) != nil
        }
    }

    private static func containsPositiveTextLogValue(in values: [Any]) -> Bool {
        for value in values {
            if let text = value as? String, containsPositiveLoggedAmount(in: text) {
                return true
            }

            if let array = value as? [Any], containsPositiveTextLogValue(in: array) {
                return true
            }

            if let dictionary = value as? [String: Any],
               containsPositiveTextLogValue(in: Array(dictionary.values)) {
                return true
            }
        }

        return false
    }

    private static func positiveDouble(from value: Any) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double > 0 ? double : nil
        }

        guard let string = value as? String else {
            return nil
        }

        let normalized = string.replacingOccurrences(of: ",", with: ".")
        guard let double = Double(normalized.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return double > 0 ? double : nil
    }

    private var containsPositivePlainAmountValue: Bool {
        contains { key, value in
            let normalizedKey = key.lowercased()
            guard normalizedKey == "title" ||
                    normalizedKey == "value" ||
                    normalizedKey == "content" ||
                    normalizedKey == "html" else {
                return false
            }

            return Self.positivePlainAmount(from: value) != nil
        }
    }

    private static func positivePlainAmount(from value: Any) -> Double? {
        guard let string = value as? String else {
            return nil
        }

        let normalized = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let double = Double(normalized) else {
            return nil
        }
        return double > 0 ? double : nil
    }

    private static func containsPositiveLoggedAmount(in text: String) -> Bool {
        if containsPositiveInputValue(named: "km_amount", in: text) {
            return true
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"([0-9]+(?:[,.][0-9]+)?)\s*(?:km|kilometri|kilomet)"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).contains { match in
            guard match.numberOfRanges > 1,
                  let amountRange = Range(match.range(at: 1), in: text) else {
                return false
            }

            let amount = text[amountRange].replacingOccurrences(of: ",", with: ".")
            return (Double(amount) ?? 0) > 0
        }
    }

    private static func containsPositiveInputValue(named name: String, in text: String) -> Bool {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let inputRegex = try? NSRegularExpression(pattern: #"<input\b[^>]*>"#, options: [.caseInsensitive]),
              let nameRegex = try? NSRegularExpression(
                pattern: #"\bname\s*=\s*(?:["']|&quot;)?\#(escapedName)(?:["']|&quot;)?"#,
                options: [.caseInsensitive]
              ),
              let valueRegex = try? NSRegularExpression(
                pattern: #"\bvalue\s*=\s*(?:["']|&quot;)?([0-9]+(?:[,.][0-9]+)?)(?:["']|&quot;)?"#,
                options: [.caseInsensitive]
              ) else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return inputRegex.matches(in: text, range: range).contains { inputMatch in
            guard let textTagRange = Range(inputMatch.range, in: text) else {
                return false
            }

            let tag = String(text[textTagRange])
            let tagRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            guard nameRegex.firstMatch(in: tag, range: tagRange) != nil,
                  let valueMatch = valueRegex.firstMatch(in: tag, range: tagRange),
                  valueMatch.numberOfRanges > 1,
                  let amountRange = Range(valueMatch.range(at: 1), in: tag) else {
                return false
            }

            let amount = tag[amountRange].replacingOccurrences(of: ",", with: ".")
            return (Double(amount) ?? 0) > 0
        }
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
    case teamNotFound
    case teamRankingNotFound
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
        case .teamNotFound:
            return "Could not find your Kilometrikisa team from your profile."
        case .teamRankingNotFound:
            return "Could not read the Kilometrikisa team ranking table."
        case .requestFailed(let status, let body):
            return "Kilometrikisa request failed with HTTP \(status). \(body)"
        }
    }
}

private extension String {
    var nonEmptyPath: String? {
        isEmpty ? nil : self
    }
}
