import Foundation

struct DailyRide: Identifiable, Codable, Equatable {
    var id: String { dateString }

    let date: Date
    var distanceKilometers: Double
    var durationSeconds: TimeInterval
    var isElectric: Bool
    var routeSegments: [[RoutePoint]] = []

    var dateString: String {
        Self.dateFormatter.string(from: date)
    }

    var hours: Int {
        Int(durationSeconds) / 3600
    }

    var minutes: Int {
        (Int(durationSeconds) % 3600) / 60
    }

    var roundedDistance: Double {
        (distanceKilometers * 100).rounded() / 100
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct RoutePoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct KilometrikisaSettings: Codable, Equatable {
    var username: String = ""
    var defaultElectric: Bool = false
}

struct TeamRanking: Equatable {
    let name: String
    let path: String
    let rows: [TeamRankingRow]
}

struct TeamRankingRow: Identifiable, Equatable {
    var id: Int { rank }

    let rank: Int
    let name: String
    let totalKilometers: String
    let muscleKilometers: String
    let electricKilometers: String
    let rideDays: Int
    let isCurrentUser: Bool
}

enum UploadState: Equatable {
    case idle
    case authorizingHealth
    case loadingHealthWorkouts
    case importingHealth(current: Int, total: Int)
    case loggingIn
    case discoveringContest
    case checkingExistingLogs
    case loadingTeamRanking
    case uploading(current: Int, total: Int)
    case done(String)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .authorizingHealth, .loadingHealthWorkouts, .importingHealth, .loggingIn, .discoveringContest, .checkingExistingLogs, .loadingTeamRanking, .uploading:
            return true
        case .idle, .done, .failed:
            return false
        }
    }

    var isImportingHealth: Bool {
        switch self {
        case .authorizingHealth, .loadingHealthWorkouts, .importingHealth:
            return true
        case .idle, .loggingIn, .discoveringContest, .checkingExistingLogs, .loadingTeamRanking, .uploading, .done, .failed:
            return false
        }
    }
}
