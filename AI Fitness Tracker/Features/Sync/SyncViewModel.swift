import Foundation
import Combine

@MainActor
final class SyncViewModel: ObservableObject {
    enum SyncStatus: Equatable {
        case idle
        case requestingPermission
        case readingHealthData
        case uploading
        case success(AppleHealthImportResponse)
        case failure(String)
    }

    @Published var status: SyncStatus = .idle
    @Published var ingestKey: String = KeychainStore.loadIngestKey()
    @Published var initialSyncDays = 30
    @Published var lastSuccessfulSyncDate: Date?
    @Published var payloadSummary: String = ""
    @Published var diagnosticsReport: WorkoutDiagnosticsReport?
    @Published var diagnosticsReportURL: URL?
    @Published var diagnosticsError: String?
    @Published var isInspectingWorkout = false

    private let healthKitManager = HealthKitManager.shared
    private let reader = HealthKitReader()
    private let apiClient = APIClient()
    private let diagnosticsInspector = WorkoutDiagnosticsInspector()
    private var stateStore = SyncStateStore()

    init() {
        lastSuccessfulSyncDate = stateStore.lastSuccessfulSyncDate
    }

    var isBusy: Bool {
        if isInspectingWorkout { return true }
        switch status {
        case .requestingPermission, .readingHealthData, .uploading:
            return true
        default:
            return false
        }
    }

    func saveIngestKey() {
        do {
            try KeychainStore.saveIngestKey(ingestKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func sync() async {
        do {
            status = .requestingPermission
            try await healthKitManager.requestAuthorization()

            status = .readingHealthData
            let mapper = HealthKitMapper(reader: reader)
            let startDate = stateStore.startDate(fallbackDays: initialSyncDays)
            let payload = try await mapper.makeRequest(from: startDate)
            let metricSampleCount = payload.workouts.reduce(0) { total, workout in
                total + workout.samples.count
            }

            payloadSummary = "\(payload.weights.count) weights • \(payload.workouts.count) workouts • \(metricSampleCount) workout samples"

            status = .uploading
            let response = try await apiClient.importAppleHealth(
                payload: payload,
                ingestKey: ingestKey
            )

            let now = Date()
            stateStore.lastSuccessfulSyncDate = now
            lastSuccessfulSyncDate = now
            status = .success(response)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func inspectLatestAdidasRun() async {
        diagnosticsError = nil
        diagnosticsReport = nil
        diagnosticsReportURL = nil
        isInspectingWorkout = true
        defer { isInspectingWorkout = false }

        do {
            try await healthKitManager.requestAuthorization()
            let report = try await diagnosticsInspector.inspectLatestAdidasRun()
            let reportURL = try diagnosticsInspector.writeJSONReport(report)
            diagnosticsReport = report
            diagnosticsReportURL = reportURL
        } catch {
            diagnosticsError = error.localizedDescription
        }
    }

    func resetSyncHistory() {
        stateStore.lastSuccessfulSyncDate = nil
        lastSuccessfulSyncDate = nil
        status = .idle
        payloadSummary = ""
    }
}
