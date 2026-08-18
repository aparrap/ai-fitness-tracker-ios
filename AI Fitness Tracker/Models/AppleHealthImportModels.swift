import Foundation

/// Backend DTOs for POST /api/v1/import/apple-health.
///
/// IMPORTANT: The backend endpoint already exists. Keep changes to its wire contract
/// isolated in this file and `HealthKitMapper.swift`.
struct AppleHealthImportRequest: Codable {
    let syncId: String
    let profileId: String
    let source: String
    let exportedAt: Date
    let weights: [AppleHealthWeight]
    let workouts: [AppleHealthWorkout]
    let metricSamples: [AppleHealthMetricSample]
}

struct AppleHealthWeight: Codable, Identifiable {
    let id: String
    let recordedAt: Date
    let weightKg: Double
    let sourceName: String?
}

struct AppleHealthWorkout: Codable, Identifiable {
    let id: String
    let activityType: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let distanceKm: Double?
    let activeEnergyKcal: Double?
    let averageHeartRateBpm: Double?
    let sourceName: String?
}

struct AppleHealthMetricSample: Codable, Identifiable {
    let id: String
    let metric: String
    let recordedAt: Date
    let value: Double
    let unit: String
    let sourceName: String?
}

struct AppleHealthImportResponse: Codable {
    let syncId: String
    let status: String
    let replayed: Bool
    let weightsProcessed: Int
    let workoutsProcessed: Int
    let workoutsMatched: Int
    let metricSamplesProcessed: Int
}
