import Foundation

struct SyncStateStore {
    private let defaults = UserDefaults.standard
    private let lastSuccessfulSyncKey = "apple-health.last-successful-sync"

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
}
