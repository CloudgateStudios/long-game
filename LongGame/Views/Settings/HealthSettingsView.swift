import SwiftUI

/// Where workouts and recovery data come from and how the last read went.
struct HealthSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var isSyncing: Bool { environment.healthState == .syncing }

    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: sourceText)
                if environment.healthSource != nil {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if isSyncing { ProgressView().controlSize(.small) }
                            Text(isSyncing ? environment.healthSyncText : environment.healthStatusText)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                    if environment.healthState == .needsAuthorization {
                        Button("Connect Apple Health") {
                            Task { await environment.connectHealth() }
                        }
                    } else {
                        Button("Sync Now") {
                            Task { await environment.syncHealth(force: true) }
                        }
                        .disabled(isSyncing)
                    }
                }
            } footer: {
                if environment.healthSource == nil {
                    Text("Health is read on your iPhone and reaches this device through iCloud.")
                } else if environment.storeKind != .fixture {
                    Text(
                        "Long Game only reads from Health. Health does not say which permissions were granted, so a type you declined simply shows no data. Change permissions in the Health app under Sharing."
                    )
                }
            }

            if environment.healthSource != nil, environment.healthState != .needsAuthorization {
                Section {
                    Button("Read Everything Again") {
                        Task { await environment.resyncHealth() }
                    }
                    .disabled(isSyncing)
                } footer: {
                    Text(
                        "Reads the whole 90 days again instead of only what is new. Use it if something looks missing.")
                }
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .navigationTitle("Health Data")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var sourceText: String {
        switch environment.storeKind {
        case .fixture: "Sample data"
        case .cloudKit, .localOnly: environment.healthSource == nil ? "Synced from iPhone" : "Apple Health"
        }
    }
}

extension AppEnvironment {
    /// Where the Health read stands, in a few words.
    var healthStatusText: String {
        switch healthState {
        case .viewer: "From iPhone"
        case .needsAuthorization: "Not connected"
        case .idle: "Waiting"
        case .syncing: "Syncing…"
        case .synced(let date): "Synced \(date.formatted(date: .omitted, time: .shortened))"
        case .failed: "Sync failed"
        }
    }
}
