import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    LabeledContent("Server") {
                        Text("Render")
                    }
                    Text(APIConfiguration.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Ingest key") {
                    SecureField("APPLE_HEALTH_INGEST_API_KEY", text: $viewModel.ingestKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Stored in the iPhone Keychain. It is not committed to this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("First sync") {
                    Picker("History to import", selection: $viewModel.initialSyncDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }

                    Button("Reset sync history", role: .destructive) {
                        viewModel.resetSyncHistory()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.saveIngestKey()
                        dismiss()
                    }
                }
            }
        }
    }
}
