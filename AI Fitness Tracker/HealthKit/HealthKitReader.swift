import Foundation
import HealthKit

struct WorkoutQuantitySamples {
    let samples: [HKQuantitySample]
    let associationKind: String
}

struct AnchoredWorkoutChanges {
    let added: [HKWorkout]
    let deleted: [HKDeletedObject]
    let newAnchor: HKQueryAnchor?
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

    func workoutChanges(
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> AnchoredWorkoutChanges {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(
                    returning: AnchoredWorkoutChanges(
                        added: samples as? [HKWorkout] ?? [],
                        deleted: deletedObjects ?? [],
                        newAnchor: newAnchor
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    /// Reads samples explicitly associated with a workout first. If the source app did not
    /// associate that metric with the workout, falls back to samples inside the workout time
    /// window while preserving that distinction in `associationKind`.
    func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        for workout: HKWorkout,
        excludingSamplesAssociatedWith overlappingWorkouts: [HKWorkout] = []
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

        let reservedSampleIDs = try await associatedSampleIDs(
            type: quantityType,
            workouts: overlappingWorkouts
        )
        let intervalPredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )
        let intervalSamples = try await samples(type: quantityType, predicate: intervalPredicate)
        let eligibleIntervalSamples = intervalSamples.filter { sample in
            !reservedSampleIDs.contains(sample.uuid)
                && fallbackSampleBelongsToWorkout(
                    sample,
                    workout: workout,
                    overlappingWorkouts: overlappingWorkouts
                )
        }
        let canonicalSamples = canonicalFallbackSamples(
            from: eligibleIntervalSamples,
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
        return try await workoutSamples(predicate: predicate)
    }

    func workoutsOverlapping(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )
        return try await workoutSamples(predicate: predicate)
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

    private func associatedSampleIDs(
        type: HKSampleType,
        workouts: [HKWorkout]
    ) async throws -> Set<UUID> {
        guard !workouts.isEmpty else { return [] }
        var result = Set<UUID>()
        for workout in workouts {
            let associated = try await samples(
                type: type,
                predicate: HKQuery.predicateForObjects(from: workout)
            )
            result.formUnion(associated.map(\.uuid))
        }
        return result
    }

    private func fallbackSampleBelongsToWorkout(
        _ sample: HKQuantitySample,
        workout: HKWorkout,
        overlappingWorkouts: [HKWorkout]
    ) -> Bool {
        let candidates = ([workout] + overlappingWorkouts).filter { candidate in
            sample.startDate >= candidate.startDate && sample.endDate <= candidate.endDate
        }
        guard candidates.count > 1 else { return true }

        let sampleMidpoint = sample.startDate.timeIntervalSinceReferenceDate
            + sample.endDate.timeIntervalSince(sample.startDate) / 2
        let owner = candidates.min { left, right in
            let leftMidpoint = left.startDate.timeIntervalSinceReferenceDate
                + left.endDate.timeIntervalSince(left.startDate) / 2
            let rightMidpoint = right.startDate.timeIntervalSinceReferenceDate
                + right.endDate.timeIntervalSince(right.startDate) / 2
            let leftDistance = abs(sampleMidpoint - leftMidpoint)
            let rightDistance = abs(sampleMidpoint - rightMidpoint)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            if left.duration != right.duration { return left.duration < right.duration }
            return left.uuid.uuidString < right.uuid.uuidString
        }
        return owner?.uuid == workout.uuid
    }

    private func canonicalFallbackSamples(
        from samples: [HKQuantitySample],
        preferredSourceBundleIdentifier: String
    ) -> [HKQuantitySample] {
        let ordered = samples.sorted(by: sampleOrder)
        guard ordered.count > 1 else { return ordered }

        var result: [HKQuantitySample] = []
        var component: [HKQuantitySample] = []
        var componentEnd: Date?
        var componentHasPointAtEnd = false

        func appendResolvedComponent() {
            guard !component.isEmpty else { return }
            let grouped = Dictionary(grouping: component, by: sourceDeviceKey)
            if grouped.count <= 1 {
                result.append(contentsOf: component)
            } else {
                let selected = grouped.max { left, right in
                    isStream(
                        left.value,
                        rankedBelow: right.value,
                        preferredSourceBundleIdentifier: preferredSourceBundleIdentifier
                    )
                }?.value ?? []
                result.append(contentsOf: selected)
            }
        }

        for sample in ordered {
            guard let currentEnd = componentEnd else {
                component = [sample]
                componentEnd = sample.endDate
                componentHasPointAtEnd = sample.startDate == sample.endDate
                continue
            }

            let isPoint = sample.startDate == sample.endDate
            let overlapsComponent = sample.startDate < currentEnd
                || (sample.startDate == currentEnd && (isPoint || componentHasPointAtEnd))

            if !overlapsComponent {
                appendResolvedComponent()
                component = [sample]
                componentEnd = sample.endDate
                componentHasPointAtEnd = isPoint
                continue
            }

            component.append(sample)
            if sample.endDate > currentEnd {
                componentEnd = sample.endDate
                componentHasPointAtEnd = isPoint
            } else if sample.endDate == currentEnd && isPoint {
                componentHasPointAtEnd = true
            }
        }

        appendResolvedComponent()
        return result.sorted(by: sampleOrder)
    }

    private func sampleOrder(_ left: HKQuantitySample, _ right: HKQuantitySample) -> Bool {
        if left.startDate != right.startDate { return left.startDate < right.startDate }
        if left.endDate != right.endDate { return left.endDate < right.endDate }
        return left.uuid.uuidString < right.uuid.uuidString
    }

    private func sourceDeviceKey(for sample: HKQuantitySample) -> String {
        let source = sample.sourceRevision.source
        let device = sample.device
        return [source.bundleIdentifier, device?.name, device?.model, device?.localIdentifier]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    private func isStream(
        _ left: [HKQuantitySample],
        rankedBelow right: [HKQuantitySample],
        preferredSourceBundleIdentifier: String
    ) -> Bool {
        let leftScore = streamScore(left, preferredSourceBundleIdentifier: preferredSourceBundleIdentifier)
        let rightScore = streamScore(right, preferredSourceBundleIdentifier: preferredSourceBundleIdentifier)
        if leftScore.coveredSeconds != rightScore.coveredSeconds { return leftScore.coveredSeconds < rightScore.coveredSeconds }
        if leftScore.spanSeconds != rightScore.spanSeconds { return leftScore.spanSeconds < rightScore.spanSeconds }
        if leftScore.sampleCount != rightScore.sampleCount { return leftScore.sampleCount < rightScore.sampleCount }
        if leftScore.preferredSource != rightScore.preferredSource { return !leftScore.preferredSource && rightScore.preferredSource }
        return leftScore.key > rightScore.key
    }

    private func streamScore(
        _ samples: [HKQuantitySample],
        preferredSourceBundleIdentifier: String
    ) -> (coveredSeconds: TimeInterval, spanSeconds: TimeInterval, sampleCount: Int, preferredSource: Bool, key: String) {
        let coveredSeconds = samples.reduce(0.0) { total, sample in
            total + max(0, sample.endDate.timeIntervalSince(sample.startDate))
        }
        let earliest = samples.map(\.startDate).min()
        let latest = samples.map(\.endDate).max()
        let spanSeconds = earliest.flatMap { first in latest.map { max(0, $0.timeIntervalSince(first)) } } ?? 0
        let sourceBundleIdentifier = samples.first?.sourceRevision.source.bundleIdentifier ?? ""
        return (
            coveredSeconds,
            spanSeconds,
            samples.count,
            sourceBundleIdentifier == preferredSourceBundleIdentifier,
            samples.first.map(sourceDeviceKey) ?? ""
        )
    }

    private func workoutSamples(predicate: NSPredicate?) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
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

    private func samples(type: HKSampleType, predicate: NSPredicate?) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
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
