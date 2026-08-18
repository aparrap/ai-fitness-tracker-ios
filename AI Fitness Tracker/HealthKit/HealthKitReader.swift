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
    ///
    /// Time-window fallback can contain overlapping streams from multiple devices/apps
    /// (for example Apple Watch + iPhone). Only one canonical source/device stream is returned
    /// so interval metrics such as distance and energy cannot be double-counted downstream.
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
        let canonicalSamples = canonicalFallbackStream(
            from: intervalSamples,
            preferredSourceBundleIdentifier: workout.sourceRevision.source.bundleIdentifier
        )

        return WorkoutQuantitySamples(
            samples: canonicalSamples,
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
        let values = result.samples
            .map { $0.quantity.doubleValue(for: unit) }
            .filter { $0.isFinite && $0 > 0 && $0 <= 260 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func canonicalFallbackStream(
        from samples: [HKQuantitySample],
        preferredSourceBundleIdentifier: String
    ) -> [HKQuantitySample] {
        guard !samples.isEmpty else { return [] }

        let grouped = Dictionary(grouping: samples, by: sourceDeviceKey)
        guard grouped.count > 1 else {
            return samples.sorted { $0.startDate < $1.startDate }
        }

        let selected = grouped.max { left, right in
            isStream(left.value, rankedBelow: right.value,
                     preferredSourceBundleIdentifier: preferredSourceBundleIdentifier)
        }?.value ?? []

        return selected.sorted { left, right in
            if left.startDate == right.startDate {
                return left.uuid.uuidString < right.uuid.uuidString
            }
            return left.startDate < right.startDate
        }
    }

    private func sourceDeviceKey(for sample: HKQuantitySample) -> String {
        let source = sample.sourceRevision.source
        let device = sample.device
        return [
            source.bundleIdentifier,
            device?.name,
            device?.model,
            device?.localIdentifier
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    private func isStream(
        _ left: [HKQuantitySample],
        rankedBelow right: [HKQuantitySample],
        preferredSourceBundleIdentifier: String
    ) -> Bool {
        let leftScore = streamScore(
            left,
            preferredSourceBundleIdentifier: preferredSourceBundleIdentifier
        )
        let rightScore = streamScore(
            right,
            preferredSourceBundleIdentifier: preferredSourceBundleIdentifier
        )

        if leftScore.coveredSeconds != rightScore.coveredSeconds {
            return leftScore.coveredSeconds < rightScore.coveredSeconds
        }
        if leftScore.spanSeconds != rightScore.spanSeconds {
            return leftScore.spanSeconds < rightScore.spanSeconds
        }
        if leftScore.sampleCount != rightScore.sampleCount {
            return leftScore.sampleCount < rightScore.sampleCount
        }
        if leftScore.preferredSource != rightScore.preferredSource {
            return !leftScore.preferredSource && rightScore.preferredSource
        }
        return leftScore.key > rightScore.key
    }

    private func streamScore(
        _ samples: [HKQuantitySample],
        preferredSourceBundleIdentifier: String
    ) -> (
        coveredSeconds: TimeInterval,
        spanSeconds: TimeInterval,
        sampleCount: Int,
        preferredSource: Bool,
        key: String
    ) {
        let coveredSeconds = samples.reduce(0.0) { total, sample in
            total + max(0, sample.endDate.timeIntervalSince(sample.startDate))
        }
        let earliest = samples.map(\.startDate).min()
        let latest = samples.map(\.endDate).max()
        let spanSeconds: TimeInterval
        if let earliest, let latest {
            spanSeconds = max(0, latest.timeIntervalSince(earliest))
        } else {
            spanSeconds = 0
        }
        let sourceBundleIdentifier = samples.first?.sourceRevision.source.bundleIdentifier ?? ""

        return (
            coveredSeconds: coveredSeconds,
            spanSeconds: spanSeconds,
            sampleCount: samples.count,
            preferredSource: sourceBundleIdentifier == preferredSourceBundleIdentifier,
            key: samples.first.map(sourceDeviceKey) ?? ""
        )
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
