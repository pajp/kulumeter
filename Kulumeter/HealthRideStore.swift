import Foundation
import HealthKit

final class HealthRideStore {
    private let store = HKHealthStore()

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async throws {
        guard isHealthDataAvailable else {
            throw HealthRideError.unavailable
        }

        let workoutType = HKObjectType.workoutType()
        let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceCycling)
        var readTypes: Set<HKObjectType> = [workoutType]
        if let distanceType {
            readTypes.insert(distanceType)
        }

        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchCyclingTotals(from startDate: Date, to endDate: Date, markElectric: Bool) async throws -> [DailyRide] {
        guard isHealthDataAvailable else {
            throw HealthRideError.unavailable
        }

        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .cycling),
            HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate])
        ])

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let workouts = try await descriptor.result(for: store)
        let calendar = Calendar.current
        var totals: [Date: DailyRide] = [:]

        for workout in workouts {
            let day = calendar.startOfDay(for: workout.startDate)
            var existing = totals[day] ?? DailyRide(
                date: day,
                distanceKilometers: 0,
                durationSeconds: 0,
                isElectric: markElectric
            )

            if let distance = workout.totalDistance {
                existing.distanceKilometers += distance.doubleValue(for: .meter()) / 1000
            }
            existing.durationSeconds += workout.duration
            existing.isElectric = markElectric
            totals[day] = existing
        }

        return totals.values
            .filter { $0.distanceKilometers > 0 || $0.durationSeconds > 0 }
            .sorted { $0.date < $1.date }
    }
}

enum HealthRideError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Health data is not available on this device."
        }
    }
}
