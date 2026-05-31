import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var settings: KilometrikisaSettings
    @Published var password: String
    @Published var startDate: Date
    @Published var endDate: Date
    @Published var rides: [DailyRide] = []
    @Published var selectedRideIDs: Set<String> = []
    @Published var loggedRideIDs: Set<String> = []
    @Published var discoveredContestID: String?
    @Published var state: UploadState = .idle

    private let healthStore = HealthRideStore()
    private let client = KilometrikisaClient()
    private let settingsKey = "KilometrikisaSettings"
    private let keychainService = "nu.dll.Kulumeter.Kilometrikisa"
    private let keychainPasswordAccount = "password"

    init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(KilometrikisaSettings.self, from: data) {
            settings = decoded
        } else {
            settings = KilometrikisaSettings()
        }

        password = (try? KeychainStore.read(service: keychainService, account: keychainPasswordAccount)) ?? ""

        let calendar = Calendar.current
        let now = Date()
        startDate = calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: now)) ?? now
        endDate = now
    }

    var selectedRides: [DailyRide] {
        rides.filter { selectedRideIDs.contains($0.id) }
    }

    var totalDistance: Double {
        selectedRides.reduce(0) { $0 + $1.roundedDistance }
    }

    var canUpload: Bool {
        !settings.username.isEmpty &&
            !password.isEmpty &&
            !selectedRideIDs.isEmpty &&
            !state.isWorking
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        try? KeychainStore.save(password, service: keychainService, account: keychainPasswordAccount)
    }

    func importRides() async {
        state = .importing
        do {
            saveSettings()
            try await healthStore.requestAuthorization()
            let imported = try await healthStore.fetchCyclingTotals(
                from: startDate,
                to: endDate,
                markElectric: settings.defaultElectric
            )
            rides = imported
            loggedRideIDs = []

            guard !imported.isEmpty else {
                selectedRideIDs = []
                state = .done("No cycling workouts found for this period.")
                return
            }

            guard !settings.username.isEmpty, !password.isEmpty else {
                selectedRideIDs = Set(imported.map(\.id))
                state = .done("Imported \(imported.count) day\(imported.count == 1 ? "" : "s"). Add Kilometrikisa credentials to skip already logged days.")
                return
            }

            state = .loggingIn
            let session = try await client.login(username: settings.username, password: password)
            state = .discoveringContest
            let contestID = try await client.discoverContestID(session: session)
            discoveredContestID = contestID
            state = .checkingExistingLogs

            let calendar = Calendar.current
            let logStartDate = calendar.startOfDay(for: startDate)
            let logEndDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
            let loggedDates = try await client.fetchLoggedDates(
                contestID: contestID,
                from: logStartDate,
                to: logEndDate,
                session: session
            )

            loggedRideIDs = Set(imported.map(\.id).filter { loggedDates.contains($0) })
            selectedRideIDs = Set(imported.map(\.id)).subtracting(loggedRideIDs)

            if loggedRideIDs.isEmpty {
                state = .done("Imported \(imported.count) day\(imported.count == 1 ? "" : "s"). No existing Kilometrikisa entries found.")
            } else {
                state = .done("Imported \(imported.count) day\(imported.count == 1 ? "" : "s"). \(loggedRideIDs.count) already logged day\(loggedRideIDs.count == 1 ? "" : "s") left unselected.")
            }
        } catch {
            selectedRideIDs = []
            state = .failed(error.localizedDescription)
        }
    }

    func uploadSelectedRides() async {
        guard canUpload else {
            return
        }

        saveSettings()
        state = .loggingIn

        do {
            let session = try await client.login(username: settings.username, password: password)
            state = .discoveringContest
            let contestID = try await client.discoverContestID(session: session)
            discoveredContestID = contestID

            let uploads = selectedRides.sorted { $0.date < $1.date }
            for (index, ride) in uploads.enumerated() {
                state = .uploading(current: index + 1, total: uploads.count)
                try await client.upload(ride, contestID: contestID, session: session)
            }
            state = .done("Uploaded \(uploads.count) day\(uploads.count == 1 ? "" : "s") to Kilometrikisa contest \(contestID).")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func toggleSelection(for ride: DailyRide) {
        if selectedRideIDs.contains(ride.id) {
            selectedRideIDs.remove(ride.id)
        } else {
            selectedRideIDs.insert(ride.id)
        }
    }
}
