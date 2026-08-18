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

    init(reader: HealthKitReader) {
        self.reader = reader
    }

    func makeRequest(from startDate: Date, to endDate: Date = Date()) async throws -> AppleHealthImportRequest {
        async let weightSamples = reader.quantitySamples(identifier: .bodyMass, from: startDate, to: endDate)
        async let workoutSamples = reader.workouts(from: startDate, to: endDate)

        let weights = try await weightSamples.map(mapWeight)
        let healthWorkouts = try await workoutSamples
        var workouts: [AppleHealthWorkout] = []
        workouts.reserveCapacity(healthWorkouts.count)

        for workout in healthWorkouts {
            workouts.append(try await mapWorkout(workout))
        }

        return AppleHealthImportRequest(
            syncId: "iphone-\(ISO8601DateFormatter().string(from: endDate))-\(UUID().uuidString.lowercased())",
            exportedAt: endDate,
            device: deviceMetadata(),
            weights: weights,
            workouts: workouts
        )
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

        for definition in definitions {
            let queryResult = try await reader.quantitySamples(
                identifier: definition.identifier,
                for: workout
            )

            result.append(contentsOf: queryResult.samples.map { sample in
                AppleHealthWorkoutSample(
                    sourceRecordId: sample.uuid.uuidString.lowercased(),
                    metric: definition.metric,
                    sampledAt: sample.startDate,
                    sampleEndedAt: sample.endDate,
                    value: sample.quantity.doubleValue(for: definition.unit),
                    unit: definition.unitName,
                    associationKind: queryResult.associationKind,
                    aggregation: definition.aggregation,
                    sourceName: sample.sourceRevision.source.name,
                    sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier
                )
            })
        }

        return result.sorted { left, right in
            if left.sampledAt == right.sampledAt {
                return left.metric < right.metric
            }
            return left.sampledAt < right.sampledAt
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
