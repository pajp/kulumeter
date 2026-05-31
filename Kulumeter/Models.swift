import Foundation

struct DailyRide: Identifiable, Codable, Equatable {
    var id: String { dateString }

    let date: Date
    var distanceKilometers: Double
    var durationSeconds: TimeInterval
    var isElectric: Bool

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

struct KilometrikisaSettings: Codable, Equatable {
    var username: String = ""
    var defaultElectric: Bool = false
}

enum UploadState: Equatable {
    case idle
    case importing
    case loggingIn
    case discoveringContest
    case checkingExistingLogs
    case uploading(current: Int, total: Int)
    case done(String)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .importing, .loggingIn, .discoveringContest, .checkingExistingLogs, .uploading:
            return true
        case .idle, .done, .failed:
            return false
        }
    }
}
