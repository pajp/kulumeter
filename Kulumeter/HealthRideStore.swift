import CoreLocation
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
        let routeType = HKSeriesType.workoutRoute()
        var readTypes: Set<HKObjectType> = [workoutType, routeType]
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
            existing.routeSegments.append(contentsOf: try await fetchRouteSegments(for: workout))
            totals[day] = existing
        }

        return totals.values
            .filter { $0.distanceKilometers > 0 || $0.durationSeconds > 0 }
            .sorted { $0.date < $1.date }
    }

    private func fetchRouteSegments(for workout: HKWorkout) async throws -> [[RoutePoint]] {
        let routes = try await fetchRoutes(for: workout)
        var segments: [[RoutePoint]] = []

        for route in routes {
            let points = try await fetchPoints(for: route)
            if points.count > 1 {
                segments.append(points)
            }
        }

        return segments
    }

    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            let routeType = HKSeriesType.workoutRoute()
            let predicate = HKQuery.predicateForObjects(from: workout)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }

            store.execute(query)
        }
    }

    private func fetchPoints(for route: HKWorkoutRoute) async throws -> [RoutePoint] {
        try await withCheckedThrowingContinuation { continuation in
            var points: [RoutePoint] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let locations {
                    points.append(contentsOf: locations.map {
                        RoutePoint(
                            latitude: $0.coordinate.latitude,
                            longitude: $0.coordinate.longitude
                        )
                    })
                }

                if done {
                    continuation.resume(returning: points)
                }
            }

            store.execute(query)
        }
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
