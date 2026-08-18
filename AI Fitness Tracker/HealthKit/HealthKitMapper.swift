import Foundation
import HealthKit
import UIKit

final class HealthKitMapper {
    private struct MetricDefinition {
        let identifier: HKQuantityTypeIdentifier
        let metric: String
        let unit: HKUnit
        let unitName: String
        let aggregation: String
    }

    private let reader: HealthKitReader
    private let maxConcurrentWorkoutMappings = 2
    private let maxConcurrentMetricQueries = 3

    init(reader: HealthKitReader) {
        self.reader = reader
    }

    func makeRequest(from startDate: Date, to endDate: Date = Date()) async throws -> AppleHealthImportRequest {
        async let weightSamples = reader.quantitySamples(identifier: .bodyMass, from: startDate, to: endDate)
        async let workoutSamples = reader.workouts(from: startDate, to: endDate)

        let weights = try await weightSamples.map(mapWeight)
        let healthWorkouts = try await workoutSamples
        let workouts = try await mapWorkouts(healthWorkouts)

        return AppleHealthImportRequest(
            syncId: "iphone-\(ISO8601DateFormatter().string(from: endDate))-\(UUID().uuidString.lowercased())",
            exportedAt: endDate,
            device: deviceMetadata(),
            weights: weights,
            workouts: workouts
        )
    }

    private func mapWorkouts(_ healthWorkouts: [HKWorkout]) async throws -> [AppleHealthWorkout] {
        guard !healthWorkouts.isEmpty else { return [] }

        var indexedResults: [(index: Int, workout: AppleHealthWorkout)] = []
        indexedResults.reserveCapacity(healthWorkouts.count)

        for batchStart in stride(
            from: 0,
            to: healthWorkouts.count,
            by: maxConcurrentWorkoutMappings
        ) {
            let batchEnd = min(
                batchStart + maxConcurrentWorkoutMappings,
                healthWorkouts.count
            )

            let batchResults = try await withThrowingTaskGroup(
                of: (Int, AppleHealthWorkout).self,
                returning: [(Int, AppleHealthWorkout)].self
            ) { group in
                for index in batchStart..<batchEnd {
                    let workout = healthWorkouts[index]
                    group.addTask { [self] in
                        (index, try await mapWorkout(workout))
                    }
                }

                var results: [(Int, AppleHealthWorkout)] = []
                results.reserveCapacity(batchEnd - batchStart)
                for try await result in group {
                    results.append(result)
                }
                return results
            }

            indexedResults.append(contentsOf: batchResults)
        }

        return indexedResults
            .sorted { $0.index < $1.index }
            .map { $0.workout }
    }

    private func mapWeight(_ sample: HKQuantitySample) -> AppleHealthWeight {
        AppleHealthWeight(
            sourceRecordId: sample.uuid.uuidString.lowercased(),
            measuredAt: sample.startDate,
            measuredOn: localDateString(sample.startDate),
            weightKg: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
            heightCm: nil
        )
    }

    private func mapWorkout(_ workout: HKWorkout) async throws -> AppleHealthWorkout {
        let samples = try await detailedSamples(for: workout)
        let heartRates = samples
            .filter { $0.metric == "heart_rate" }
            .map(\.value)

        let averageHeartRate: Double? = heartRates.isEmpty
            ? nil
            : heartRates.reduce(0, +) / Double(heartRates.count)
        let maximumHeartRate = heartRates.max()
        let source = workout.sourceRevision.source

        return AppleHealthWorkout(
            sourceRecordId: workout.uuid.uuidString.lowercased(),
            activityType: workoutName(workout.workoutActivityType),
            title: workout.workoutActivityType == .running ? "Running" : nil,
            startedAt: workout.startDate,
            startedOn: localDateString(workout.startDate),
            endedAt: workout.endDate,
            durationSeconds: Int(workout.duration.rounded()),
            distanceM: workout.totalDistance?.doubleValue(for: .meter()),
            activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
            elevationGainM: nil,
            avgHeartRateBpm: averageHeartRate,
            maxHeartRateBpm: maximumHeartRate,
            sourceName: source.name,
            sourceBundleIdentifier: source.bundleIdentifier,
            samples: samples
        )
    }

    private func detailedSamples(for workout: HKWorkout) async throws -> [AppleHealthWorkoutSample] {
        var definitions = [
            MetricDefinition(
                identifier: .heartRate,
                metric: "heart_rate",
                unit: HKUnit.count().unitDivided(by: .minute()),
                unitName: "bpm",
                aggregation: "instantaneous"
            )
        ]

        if workout.workoutActivityType == .running {
            definitions += [
                MetricDefinition(
                    identifier: .runningSpeed,
                    metric: "running_speed",
                    unit: .meter().unitDivided(by: .second()),
                    unitName: "m/s",
                    aggregation: "instantaneous"
                ),
                MetricDefinition(
                    identifier: .distanceWalkingRunning,
                    metric: "distance",
                    unit: .meter(),
                    unitName: "m",
                    aggregation: "interval_delta"
                ),
                MetricDefinition(
                    identifier: .activeEnergyBurned,
                    metric: "active_energy",
                    unit: .kilocalorie(),
                    unitName: "kcal",
                    aggregation: "interval_delta"
                ),
                MetricDefinition(
                    identifier: .stepCount,
                    metric: "step_count",
                    unit: .count(),
                    unitName: "count",
                    aggregation: "interval_delta"
                ),
                MetricDefinition(
                    identifier: .runningPower,
                    metric: "running_power",
                    unit: .watt(),
                    unitName: "W",
                    aggregation: "instantaneous"
                ),
                MetricDefinition(
                    identifier: .runningStrideLength,
                    metric: "running_stride_length",
                    unit: .meter(),
                    unitName: "m",
                    aggregation: "instantaneous"
                ),
                MetricDefinition(
                    identifier: .runningVerticalOscillation,
                    metric: "running_vertical_oscillation",
                    unit: .meter(),
                    unitName: "m",
                    aggregation: "instantaneous"
                ),
                MetricDefinition(
                    identifier: .runningGroundContactTime,
                    metric: "running_ground_contact_time",
                    unit: HKUnit.secondUnit(with: .milli),
                    unitName: "ms",
                    aggregation: "instantaneous"
                )
            ]
        }

        var result: [AppleHealthWorkoutSample] = []

        for batchStart in stride(
            from: 0,
            to: definitions.count,
            by: maxConcurrentMetricQueries
        ) {
            let batchEnd = min(
                batchStart + maxConcurrentMetricQueries,
                definitions.count
            )
            let batch = Array(definitions[batchStart..<batchEnd])

            let batchSamples = try await withThrowingTaskGroup(
                of: [AppleHealthWorkoutSample].self,
                returning: [AppleHealthWorkoutSample].self
            ) { group in
                for definition in batch {
                    group.addTask { [reader] in
                        let queryResult = try await reader.quantitySamples(
                            identifier: definition.identifier,
                            for: workout
                        )

                        return queryResult.samples.compactMap { sample in
                            let value = sample.quantity.doubleValue(for: definition.unit)
                            guard Self.isValidMetricValue(value, metric: definition.metric) else {
                                return nil
                            }

                            return AppleHealthWorkoutSample(
                                sourceRecordId: sample.uuid.uuidString.lowercased(),
                                metric: definition.metric,
                                sampledAt: sample.startDate,
                                sampleEndedAt: sample.endDate,
                                value: value,
                                unit: definition.unitName,
                                associationKind: queryResult.associationKind,
                                aggregation: definition.aggregation,
                                sourceName: sample.sourceRevision.source.name,
                                sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier
                            )
                        }
                    }
                }

                var mapped: [AppleHealthWorkoutSample] = []
                for try await samples in group {
                    mapped.append(contentsOf: samples)
                }
                return mapped
            }

            result.append(contentsOf: batchSamples)
        }

        return result.sorted { left, right in
            if left.sampledAt == right.sampledAt {
                if left.metric == right.metric {
                    return left.sourceRecordId < right.sourceRecordId
                }
                return left.metric < right.metric
            }
            return left.sampledAt < right.sampledAt
        }
    }

    private static func isValidMetricValue(_ value: Double, metric: String) -> Bool {
        guard value.isFinite else { return false }

        switch metric {
        case "heart_rate":
            return value > 0 && value <= 260
        case "running_speed",
             "distance",
             "active_energy",
             "step_count",
             "running_power",
             "running_stride_length",
             "running_vertical_oscillation",
             "running_ground_contact_time":
            return value >= 0
        default:
            return false
        }
    }

    private func deviceMetadata() -> AppleHealthDevice {
        let device = UIDevice.current
        return AppleHealthDevice(
            name: device.name,
            model: device.model,
            systemVersion: device.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

    private func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func workoutName(_ activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .boxing: return "boxing"
        case .traditionalStrengthTraining: return "strength_training"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .highIntensityIntervalTraining: return "hiit"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        default: return "other_\(activity.rawValue)"
        }
    }
}
