import Foundation

/// Wire contract for POST /api/v1/import/apple-health.
/// Keep these DTOs aligned with the backend Apple Health schema.
struct AppleHealthImportRequest: Codable {
    let syncId: String
    let exportedAt: Date
    let device: AppleHealthDevice?
    let weights: [AppleHealthWeight]
    let workouts: [AppleHealthWorkout]
}

struct AppleHealthDevice: Codable {
    let name: String?
    let model: String?
    let systemVersion: String?
    let appVersion: String?
}

struct AppleHealthWeight: Codable {
    let sourceRecordId: String
    let measuredAt: Date
    let measuredOn: String
    let weightKg: Double
    let heightCm: Double?
}

struct AppleHealthWorkout: Codable {
    let sourceRecordId: String
    let activityType: String
    let title: String?
    let startedAt: Date
    let startedOn: String
    let endedAt: Date
    let durationSeconds: Int?
    let distanceM: Double?
    let activeEnergyKcal: Double?
    let elevationGainM: Double?
    let avgHeartRateBpm: Double?
    let maxHeartRateBpm: Double?
    let sourceName: String?
    let sourceBundleIdentifier: String?
    let samples: [AppleHealthWorkoutSample]
}

struct AppleHealthWorkoutSample: Codable, Identifiable {
    var id: String { sourceRecordId }

    let sourceRecordId: String
    let metric: String
    let sampledAt: Date
    let sampleEndedAt: Date?
    let value: Double
    let unit: String
    let associationKind: String
    let aggregation: String?
    let sourceName: String?
    let sourceBundleIdentifier: String?
}

struct AppleHealthImportResponse: Codable, Equatable {
    let syncId: String
    let status: String
    let replayed: Bool
    let weightsProcessed: Int
    let workoutsProcessed: Int
    let workoutsMatched: Int
    let metricSamplesProcessed: Int
}
