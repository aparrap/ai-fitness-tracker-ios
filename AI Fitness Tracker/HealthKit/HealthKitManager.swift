import Foundation
import HealthKit

final class HealthKitManager {
    static let shared = HealthKitManager()

    let healthStore = HKHealthStore()

    private init() {}

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()

        [
            HKQuantityTypeIdentifier.bodyMass,
            .heartRate,
            .stepCount,
            .activeEnergyBurned,
            .distanceWalkingRunning,
            .runningSpeed,
            .runningPower,
            .runningStrideLength,
            .runningVerticalOscillation,
            .runningGroundContactTime
        ].forEach { identifier in
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }

        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        return types
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.healthDataUnavailable
        }

        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }
}
