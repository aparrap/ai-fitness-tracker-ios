import Foundation
import HealthKit
import UserNotifications

final class HealthKitManager {
    static let shared = HealthKitManager()

    let healthStore: HKHealthStore

    private init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    var readTypes: Set<HKObjectType> {
        var result = Set<HKObjectType>()

        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .bodyMass,
            .heartRate,
            .stepCount,
            .activeEnergyBurned,
            .distanceWalkingRunning,
            .runningSpeed,
            .runningPower,
            .runningStrideLength,
            .runningVerticalOscillation,
            .runningGroundContactTime
        ]

        quantityIdentifiers.forEach { identifier in
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                result.insert(type)
            }
        }

        result.insert(HKObjectType.workoutType())
        result.insert(HKSeriesType.workoutRoute())
        return result
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.healthDataUnavailable
        }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    func enableWorkoutBackgroundDelivery() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            healthStore.enableBackgroundDelivery(
                for: HKObjectType.workoutType(),
                frequency: .immediate
            ) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: HealthKitError.authorizationFailed)
                }
            }
        }
    }
}

final class AutomaticHealthSyncCoordinator {
    static let shared = AutomaticHealthSyncCoordinator()

    private let healthStore: HKHealthStore
    private let worker: AutomaticHealthSyncWorker
    private let observerLock = NSLock()
    private var observerQuery: HKObserverQuery?

    private init(
        healthStore: HKHealthStore = HealthKitManager.shared.healthStore,
        worker: AutomaticHealthSyncWorker = AutomaticHealthSyncWorker()
    ) {
        self.healthStore = healthStore
        self.worker = worker
    }

    /// Must be called as early as possible during app launch so HealthKit can deliver
    /// background observer callbacks to a registered query.
    func registerObserver() {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard observerQuery == nil else { return }

        let query = HKObserverQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: nil
        ) { [weak self] _, completionHandler, error in
            guard let self else {
                completionHandler()
                return
            }

            guard error == nil else {
                completionHandler()
                return
            }

            Task {
                await self.worker.synchronizeAvailableChanges()
                completionHandler()
            }
        }

        observerQuery = query
        healthStore.execute(query)
    }

    func activate() async {
        do {
            try await HealthKitManager.shared.requestAuthorization()
            await CoachingNotificationService.prepareAuthorization()
            try await HealthKitManager.shared.enableWorkoutBackgroundDelivery()
            await worker.synchronizeAvailableChanges()
        } catch {
            print("Automatic HealthKit sync activation failed: \(error.localizedDescription)")
        }
    }
}

actor AutomaticHealthSyncWorker {
    private let reader: HealthKitReader
    private let mapper: HealthKitMapper
    private let apiClient: APIClient
    private var stateStore: SyncStateStore
    private let pageSize = 100
    private let maxPagesPerWake = 1000

    init(
        reader: HealthKitReader = HealthKitReader(),
        apiClient: APIClient = APIClient(),
        stateStore: SyncStateStore = SyncStateStore()
    ) {
        self.reader = reader
        self.mapper = HealthKitMapper(reader: reader)
        self.apiClient = apiClient
        self.stateStore = stateStore
    }

    func synchronizeAvailableChanges() async {
        do {
            try await synchronize()
        } catch {
            print("Automatic HealthKit sync failed: \(error.localizedDescription)")
        }
    }

    private func synchronize() async throws {
        let ingestKey = KeychainStore.loadIngestKey()
        guard !ingestKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.missingIngestKey
        }

        var anchor = stateStore.workoutAnchor()
        let bootstrap = anchor == nil
        let bootstrapCutoff = stateStore.startDate(fallbackDays: 30)

        for _ in 0..<maxPagesPerWake {
            let changes = try await reader.workoutChanges(anchor: anchor, limit: pageSize)
            let workouts = bootstrap
                ? changes.added.filter { $0.endDate >= bootstrapCutoff }
                : changes.added
            let deletedIds = changes.deleted.map { $0.uuid.uuidString.lowercased() }

            if !workouts.isEmpty || !deletedIds.isEmpty {
                let exportedAt = Date()
                let syncId = stateStore.createPendingAutomaticSyncId()
                let request = try await mapper.makeIncrementalRequest(
                    workouts: workouts,
                    deletedWorkoutSourceRecordIds: deletedIds,
                    exportedAt: exportedAt,
                    syncId: syncId
                )
                let response = try await apiClient.importAppleHealth(
                    payload: request,
                    ingestKey: ingestKey
                )
                await CoachingNotificationService.notify(from: response)

                // Clear only after backend acceptance. If the app is killed before this point,
                // the same HealthKit page reuses the same backend idempotency key on retry.
                stateStore.clearPendingAutomaticSyncId()
            }

            // Advance the HealthKit cursor only after the corresponding backend page succeeds.
            // If saving the cursor fails after clearing the pending key, the page may be safely
            // reprocessed with a new sync id because backend record-level imports are idempotent.
            try stateStore.saveWorkoutAnchor(changes.newAnchor)
            anchor = changes.newAnchor

            if changes.added.count + changes.deleted.count < pageSize {
                stateStore.lastSuccessfulSyncDate = Date()
                return
            }

            guard anchor != nil else { return }
        }

        throw HealthKitError.queryFailed("HealthKit incremental sync exceeded the per-wake page limit")
    }
}

enum CoachingNotificationService {
    static func prepareAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        } catch {
            print("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    static func notify(from response: AppleHealthImportResponse) async {
        for coaching in response.coaching ?? [] where coaching.status == "completed" {
            guard let summary = coaching.summary, !summary.isEmpty else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Workout coaching ready"
            content.body = summary
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "workout-coaching-\(coaching.workoutId)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                print("Coaching notification failed: \(error.localizedDescription)")
            }
        }
    }
}
