import Models
import SwiftData
import SwiftUI

/// iCloud sync: whether it is on, how the last one went, and the details worth having
/// when it misbehaves.
struct CloudSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query private var workouts: [CompletedWorkout]
    @Query private var days: [DailyMetrics]
    @Query private var goals: [Goal]

    var body: some View {
        Form {
            Section {
                switch environment.storeKind {
                case .cloudKit:
                    LabeledContent("iCloud", value: "On")
                    if environment.iCloudAccountAvailable == false {
                        Label(
                            "This device is not signed in to iCloud, so nothing is syncing.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if environment.isImportingFromICloud || environment.isExportingToICloud {
                                ProgressView().controlSize(.small)
                            }
                            Text(statusText).multilineTextAlignment(.trailing)
                        }
                    }
                    Button("Sync with iCloud Now") {
                        Task { await environment.forceCloudSync() }
                    }
                    .disabled(!environment.canForceCloudSync)
                case .localOnly(let reason):
                    LabeledContent("iCloud", value: "Off")
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                case .fixture:
                    LabeledContent("iCloud", value: "Off")
                    // The same close-and-reopen a real iCloud sync does, so it can be rehearsed here.
                    Button("Reopen the Store (Sync Rehearsal)") {
                        Task { await environment.forceCloudSync() }
                    }
                    .disabled(!environment.canForceCloudSync)
                }
            } footer: {
                if let outcome = environment.forcedSyncOutcome {
                    Text(forcedSyncText(outcome))
                } else if environment.storeKind == .fixture {
                    Text("Running on synthetic sample data, kept in a separate store that never syncs.")
                }
            }

            if case .cloudKit(let containerID) = environment.storeKind {
                Section("Details") {
                    if let date = environment.lastExport {
                        LabeledContent("Last sent", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let date = environment.lastImport {
                        LabeledContent("Last received", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Container", value: containerID)
                    LabeledContent("Environment", value: cloudEnvironmentText)
                }
            }

            Section("On this device") {
                LabeledContent("Goals", value: goals.count.formatted())
                LabeledContent("Workouts", value: workouts.count.formatted())
                LabeledContent("Days of metrics", value: days.count.formatted())
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .navigationTitle("iCloud")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The CloudKit environment this build was configured for. Devices on different
    /// environments do not see each other's data.
    private var cloudEnvironmentText: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "LGCloudKitEnvironment") as? String ?? ""
        return value.isEmpty ? "Unknown" : value
    }

    private var statusText: String {
        if environment.isImportingFromICloud { return "Getting data…" }
        if environment.isExportingToICloud { return "Sending changes…" }
        guard let date = environment.lastSyncEvent else { return "Waiting for iCloud" }
        let time = date.formatted(date: .abbreviated, time: .shortened)
        return environment.lastSyncFailed ? "Failed \(time)" : time
    }

    private func forcedSyncText(_ outcome: AppEnvironment.ForcedSyncOutcome) -> String {
        switch outcome {
        case .finished(let date):
            environment.storeKind == .fixture
                ? "Store reopened at \(date.formatted(date: .omitted, time: .standard))."
                : "Checked iCloud at \(date.formatted(date: .omitted, time: .standard))."
        case .noReply: "The store was reopened but iCloud has not answered yet. It will carry on in the background."
        case .failed: "The sync did not complete. Check that this device is online and signed in to iCloud."
        }
    }
}

extension AppEnvironment {
    /// iCloud sync in a word or two, for the Settings row.
    var cloudSummaryText: String {
        guard case .cloudKit = storeKind else { return "Off" }
        if iCloudAccountAvailable == false { return "Signed out" }
        if isImportingFromICloud || isExportingToICloud { return "Syncing…" }
        return lastSyncFailed ? "Sync failed" : "On"
    }

    var cloudNeedsAttention: Bool {
        guard case .cloudKit = storeKind else { return false }
        return iCloudAccountAvailable == false || lastSyncFailed
    }
}
