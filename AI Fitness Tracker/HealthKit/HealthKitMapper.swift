import Foundation
import HealthKit

final class HealthKitMapper {
    private let reader: HealthKitReader

    init(reader: HealthKitReader) {
        self.reader = reader
    }

    func makeRequest(from startDate: Date, to endDate: Date = Date()) async throws -> AppleHealthImportRequest {
        async let weightSamples = reader.quantitySamples(identifier: .bodyMass, from: startDate, to: endDate)
        async let heartRateSamples = reader.quantitySamples(identifier: .heartRate, from: startDate, to: endDate)
        async let stepSamples = reader.quantitySamples(identifier: .stepCount, from: startDate, to: endDate)
        async let energySamples = reader.quantitySamples(identifier: .activeEnergyBurned, from: startDate, to: endDate)
        async let distanceSamples = reader.quantitySamples(identifier: .distanceWalkingRunning, from: startDate, to: endDate)
        async let workoutSamples = reader.workouts(from: startDate, to: endDate)

        let weights = try await weightSamples.map(mapWeight)
        let heartRates = try await heartRateSamples.map { sample in
            mapMetric(sample, metric: "heart_rate", unit: HKUnit.count().unitDivided(by: .minute()), unitName: "bpm")
        }
        let steps = try await stepSamples.map { sample in
            mapMetric(sample, metric: "steps", unit: .count(), unitName: "count")
        }
        let energies = try await energySamples.map { sample in
            mapMetric(sample, metric: "active_energy", unit: .kilocalorie(), unitName: "kcal")
        }
        let distances = try await distanceSamples.map { sample in
            mapMetric(sample, metric: "walking_running_distance", unit: .meterUnit(with: .kilo), unitName: "km")
        }

        let healthWorkouts = try await workoutSamples
        var workouts: [AppleHealthWorkout] = []
        workouts.reserveCapacity(healthWorkouts.count)

        for workout in healthWorkouts {
            let averageHeartRate = try? await reader.averageHeartRate(for: workout)
            workouts.append(mapWorkout(workout, averageHeartRateBpm: averageHeartRate))
        }

        return AppleHealthImportRequest(
            syncId: "iphone-\(ISO8601DateFormatter().string(from: endDate))-\(UUID().uuidString.lowercased())",
            profileId: APIConfiguration.profileId,
            source: "apple_health",
            exportedAt: endDate,
            weights: weights,
            workouts: workouts,
            metricSamples: heartRates + steps + energies + distances
        )
    }

    private func mapWeight(_ sample: HKQuantitySample) -> AppleHealthWeight {
        AppleHealthWeight(
            id: sample.uuid.uuidString.lowercased(),
            recordedAt: sample.startDate,
            weightKg: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
            sourceName: sample.sourceRevision.source.name
        )
    }

    private func mapMetric(
        _ sample: HKQuantitySample,
        metric: String,
        unit: HKUnit,
        unitName: String
    ) -> AppleHealthMetricSample {
        AppleHealthMetricSample(
            id: sample.uuid.uuidString.lowercased(),
            metric: metric,
            recordedAt: sample.startDate,
            value: sample.quantity.doubleValue(for: unit),
            unit: unitName,
            sourceName: sample.sourceRevision.source.name
        )
    }

    private func mapWorkout(_ workout: HKWorkout, averageHeartRateBpm: Double?) -> AppleHealthWorkout {
        AppleHealthWorkout(
            id: workout.uuid.uuidString.lowercased(),
            activityType: workoutName(workout.workoutActivityType),
            startedAt: workout.startDate,
            endedAt: workout.endDate,
            durationSeconds: workout.duration,
            distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)),
            activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
            averageHeartRateBpm: averageHeartRateBpm,
            sourceName: workout.sourceRevision.source.name
        )
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
