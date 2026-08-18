import Foundation
import HealthKit

struct WorkoutQuantitySamples {
    let samples: [HKQuantitySample]
    let associationKind: String
}

final class HealthKitReader {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HealthKitManager.shared.healthStore) {
        self.healthStore = healthStore
    }

    func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        from startDate: Date,
        to endDate: Date = Date()
    ) async throws -> [HKQuantitySample] {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw HealthKitError.unsupportedType(identifier.rawValue)
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        return try await samples(type: quantityType, predicate: predicate)
    }

    /// Reads samples explicitly associated with a workout first. If the source app did not
    /// associate that metric with the workout, falls back to samples inside the workout time
    /// window while preserving that distinction in `associationKind`.
    func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        for workout: HKWorkout
    ) async throws -> WorkoutQuantitySamples {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw HealthKitError.unsupportedType(identifier.rawValue)
        }

        let associated = try await samples(
            type: quantityType,
            predicate: HKQuery.predicateForObjects(from: workout)
        )

        if !associated.isEmpty {
            return WorkoutQuantitySamples(
                samples: associated,
                associationKind: "workout_associated"
            )
        }

        let intervalPredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )
        let intervalSamples = try await samples(
            type: quantityType,
            predicate: intervalPredicate
        )

        return WorkoutQuantitySamples(
            samples: intervalSamples,
            associationKind: "time_window"
        )
    }

    func workouts(
        from startDate: Date,
        to endDate: Date = Date()
    ) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            healthStore.execute(query)
        }
    }

    func averageHeartRate(for workout: HKWorkout) async throws -> Double? {
        let result = try await quantitySamples(identifier: .heartRate, for: workout)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let values = result.samples.map { $0.quantity.doubleValue(for: unit) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func samples(
        type: HKSampleType,
        predicate: NSPredicate?
    ) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            healthStore.execute(query)
        }
    }
}
