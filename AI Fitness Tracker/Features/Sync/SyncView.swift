import SwiftUI

struct SyncView: View {
    @StateObject private var viewModel = SyncViewModel()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    statusCard
                    syncButton
                    diagnosticsCard
                    details
                }
                .padding()
            }
            .navigationTitle("AI Fitness Tracker")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(viewModel: viewModel)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 58))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)

            Text("Apple Health Bridge")
                .font(.title2.bold())

            Text("Sync Apple Health and inspect the detailed samples attached to running workouts.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: statusIcon)
                Text(statusTitle)
                    .font(.headline)
                Spacer()
                if viewModel.isBusy && !viewModel.isInspectingWorkout {
                    ProgressView()
                }
            }

            Text(statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !viewModel.payloadSummary.isEmpty {
                Divider()
                Text(viewModel.payloadSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var syncButton: some View {
        Button {
            Task { await viewModel.sync() }
        } label: {
            Label("Sync Apple Health", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isBusy)
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Workout diagnostics", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Spacer()
                if viewModel.isInspectingWorkout {
                    ProgressView()
                }
            }

            Text("Inspects the latest adidas Running workout in HealthKit. It compares samples explicitly attached to the workout with samples merely present during the same timestamps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                Task { await viewModel.inspectLatestAdidasRun() }
            } label: {
                Label("Inspect Latest adidas Run", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)

            if let report = viewModel.diagnosticsReport {
                Divider()

                Text("\(report.workout.sourceName) • \(report.workout.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline.bold())

                diagnosticRow(
                    "Heart rate",
                    associated: report.associatedHeartRateCount,
                    interval: report.intervalHeartRateCount
                )
                diagnosticRow(
                    "Running speed",
                    associated: report.associatedRunningSpeedCount,
                    interval: report.intervalRunningSpeedCount
                )
                diagnosticRow(
                    "Distance",
                    associated: report.associatedDistanceCount,
                    interval: report.intervalDistanceCount
                )

                HStack {
                    Text("GPS route")
                    Spacer()
                    Text("\(report.routes.count) route(s) • \(report.routePointCount) points")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                HStack {
                    Text("Workout events")
                    Spacer()
                    Text("\(report.workoutEvents.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if let reportURL = viewModel.diagnosticsReportURL {
                    ShareLink(item: reportURL) {
                        Label("Share JSON Diagnostic", systemImage: "square.and.arrow.up")
                    }
                    .font(.subheadline)
                }
            }

            if let error = viewModel.diagnosticsError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func diagnosticRow(_ name: String, associated: Int, interval: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("attached \(associated) • interval \(interval)")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Body weight", systemImage: "scalemass")
            Label("Workouts", systemImage: "figure.run")
            Label("Heart rate", systemImage: "heart.fill")
            Label("Running speed", systemImage: "speedometer")
            Label("Workout route / GPS", systemImage: "map.fill")
            Label("Steps", systemImage: "shoeprints.fill")
            Label("Active energy", systemImage: "flame.fill")
            Label("Walking & running distance", systemImage: "location.fill")

            if let last = viewModel.lastSuccessfulSyncDate {
                Divider().padding(.vertical, 4)
                Text("Last successful sync: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.subheadline)
        .padding()
    }

    private var statusIcon: String {
        switch viewModel.status {
        case .idle: return "iphone"
        case .requestingPermission: return "lock.shield"
        case .readingHealthData: return "heart.text.square"
        case .uploading: return "icloud.and.arrow.up"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTitle: String {
        switch viewModel.status {
        case .idle: return "Ready to sync"
        case .requestingPermission: return "HealthKit permission"
        case .readingHealthData: return "Reading HealthKit"
        case .uploading: return "Uploading"
        case .success: return "Sync complete"
        case .failure: return "Sync failed"
        }
    }

    private var statusMessage: String {
        switch viewModel.status {
        case .idle:
            return viewModel.ingestKey.isEmpty
                ? "Open Settings and add your ingest API key first."
                : "The bridge is configured and ready."
        case .requestingPermission:
            return "Requesting permission to read your selected Apple Health data."
        case .readingHealthData:
            return "Reading weight, workouts, heart rate, steps, energy and distance."
        case .uploading:
            return "Sending the normalized HealthKit payload to Render."
        case let .success(response):
            return "Backend processed \(response.weightsProcessed) weights, \(response.workoutsProcessed) workouts and \(response.metricSamplesProcessed) metric samples."
        case let .failure(message):
            return message
        }
    }
}
