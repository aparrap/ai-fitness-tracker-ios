import Foundation
import HealthKit

struct SyncStateStore {
    private let defaults = UserDefaults.standard
    private let lastSuccessfulSyncKey = "apple-health.last-successful-sync"
    private let workoutAnchorKey = "apple-health.workout-query-anchor"

    var lastSuccessfulSyncDate: Date? {
        get { defaults.object(forKey: lastSuccessfulSyncKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: lastSuccessfulSyncKey) }
    }

    func startDate(fallbackDays: Int) -> Date {
        if let lastSuccessfulSyncDate {
            // Re-read a small overlap so samples arriving late are not missed.
            return lastSuccessfulSyncDate.addingTimeInterval(-5 * 60)
        }
        return Calendar.current.date(byAdding: .day, value: -fallbackDays, to: Date()) ?? Date()
    }

    func workoutAnchor() -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: workoutAnchorKey) else {
            return nil
        }

        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: data
        )
    }

    func saveWorkoutAnchor(_ anchor: HKQueryAnchor?) throws {
        guard let anchor else {
            defaults.removeObject(forKey: workoutAnchorKey)
            return
        }

        let data = try NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        )
        defaults.set(data, forKey: workoutAnchorKey)
    }

    func clearWorkoutAnchor() {
        defaults.removeObject(forKey: workoutAnchorKey)
    }
}
