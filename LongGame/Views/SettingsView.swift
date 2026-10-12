import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query private var workouts: [CompletedWorkout]
    @Query private var days: [DailyMetrics]
    @Query private var goals: [Goal]

    var body: some View {
        Form {
            Section {
                NavigationLink("Athlete Profile") { ProfileView() }
            } footer: {
                Text("Max heart rate, zones and FTP, used to work out training load.")
            }

            CoachSettingsSection()
            SpendingSection()
            ReminderSection()

            Section("Sync") {
                switch environment.storeKind {
                case .cloudKit(let containerID):
                    LabeledContent("iCloud", value: "On")
                    if environment.iCloudAccountAvailable == false {
                        Label(
                            "This device is not signed in to iCloud, so nothing is syncing.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Container", value: containerID)
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if environment.isImportingFromICloud || environment.isExportingToICloud {
                                ProgressView().controlSize(.small)
                            }
                            Text(cloudStatusText).multilineTextAlignment(.trailing)
                        }
                    }
                    if let date = environment.lastExport {
                        LabeledContent("Last sent", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let date = environment.lastImport {
                        LabeledContent("Last received", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Sync with iCloud Now") {
                        Task { await environment.forceCloudSync() }
                    }
                    .disabled(!environment.canForceCloudSync)
                    if let outcome = environment.forcedSyncOutcome {
                        Text(forcedSyncText(outcome)).font(.footnote).foregroundStyle(.secondary)
                    }
                case .localOnly(let reason):
                    LabeledContent("iCloud", value: "Off")
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                case .fixture:
                    LabeledContent("iCloud", value: "Off")
                    Text("Running on synthetic sample data, kept in a separate store that never syncs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // The same close-and-reopen a real iCloud sync does, so it can be rehearsed here.
                    Button("Reopen the Store (Sync Rehearsal)") {
                        Task { await environment.forceCloudSync() }
                    }
                    .disabled(!environment.canForceCloudSync)
                    if let outcome = environment.forcedSyncOutcome {
                        Text(forcedSyncText(outcome)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Source", value: sourceText)
                if environment.healthSource != nil {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if environment.healthState == .syncing { ProgressView().controlSize(.small) }
                            Text(environment.healthState == .syncing ? environment.healthSyncText : healthText)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                    switch environment.healthState {
                    case .needsAuthorization:
                        Button("Connect Apple Health") {
                            Task { await environment.connectHealth() }
                        }
                    default:
                        Button("Sync Now") {
                            Task { await environment.syncHealth(force: true) }
                        }
                        .disabled(environment.healthState == .syncing)
                        Button("Read Everything Again") {
                            Task { await environment.resyncHealth() }
                        }
                        .disabled(environment.healthState == .syncing)
                    }
                }
            } header: {
                Text("Health data")
            } footer: {
                if environment.healthSource != nil, environment.storeKind != .fixture {
                    Text(
                        "Long Game only reads from Health. Health does not say which permissions were granted, so a type you declined simply shows no data. Change permissions in the Health app under Sharing."
                    )
                }
            }

            Section("Stored") {
                LabeledContent("Goals", value: goals.count.formatted())
                LabeledContent("Workouts", value: workouts.count.formatted())
                LabeledContent("Days of metrics", value: days.count.formatted())
            }
        }
        .formStyle(.grouped)
        .readableWidth()
    }

    private var sourceText: String {
        switch environment.storeKind {
        case .fixture: "Sample data"
        case .cloudKit, .localOnly: environment.healthSource == nil ? "Synced from iPhone" : "Apple Health"
        }
    }

    private var healthText: String {
        switch environment.healthState {
        case .viewer: "Not available"
        case .needsAuthorization: "Not connected"
        case .idle: "Waiting"
        case .syncing: "Syncing…"
        case .synced(let date): "Synced \(date.formatted(date: .omitted, time: .shortened))"
        case .failed: "Sync failed"
        }
    }

    private var cloudStatusText: String {
        if environment.isImportingFromICloud { return "Getting data…" }
        if environment.isExportingToICloud { return "Sending changes…" }
        return lastSyncText
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

    private var lastSyncText: String {
        guard let date = environment.lastSyncEvent else { return "Waiting for iCloud" }
        let time = date.formatted(date: .abbreviated, time: .shortened)
        return environment.lastSyncFailed ? "Failed \(time)" : time
    }
}

/// API key and model for in-app reviews. The key goes straight to the Keychain and is
/// never shown again once saved.
private struct CoachSettingsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var draft = ""
    @State private var saveFailed = false

    var body: some View {
        @Bindable var coach = environment.coach
        Section {
            if coach.hasKey {
                LabeledContent("API key", value: "Saved")
                Button("Remove Key", role: .destructive) {
                    coach.saveKey(nil)
                }
            } else {
                SecureField("Anthropic API key", text: $draft)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                .textInputAutocapitalization(.never)
                    #endif
                Button("Save Key") {
                    saveFailed = !coach.saveKey(draft)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Picker("Model", selection: $coach.modelID) {
                ForEach(CoachConfiguration.models) { model in
                    Text(model.name).tag(model.id)
                }
            }
        } header: {
            Text("Coach")
        } footer: {
            if saveFailed {
                Text("The key could not be saved to the Keychain.")
            } else {
                Text(
                    "The key is stored in your iCloud Keychain, so your other devices get it too. API use is billed by Anthropic separately from a Claude subscription."
                )
            }
        }
    }
}

/// When the weekly review reminder fires. Changes apply as they are made.
private struct ReminderSection: View {
    @Environment(AppEnvironment.self) private var environment

    private var reminder: WeeklyReminder { environment.reminder }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(
                bySettingHour: reminder.minuteOfDay / 60, minute: reminder.minuteOfDay % 60, second: 0, of: .now)
                ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            apply(minute: (parts.hour ?? 18) * 60 + (parts.minute ?? 0))
        }
    }

    var body: some View {
        Section {
            Toggle("Weekly review reminder", isOn: Binding(get: { reminder.isEnabled }, set: { apply(enabled: $0) }))
            if reminder.isEnabled {
                Picker("Day", selection: Binding(get: { reminder.weekday }, set: { apply(weekday: $0) })) {
                    ForEach(1...7, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
            }
        } footer: {
            if reminder.isDenied {
                Text("Notifications are turned off for Long Game. Allow them in system settings to use the reminder.")
            } else {
                Text(
                    "Opening the app from the reminder starts that week's review. Without an API key it just opens the Coach tab."
                )
            }
        }
    }

    private func apply(enabled: Bool? = nil, weekday: Int? = nil, minute: Int? = nil) {
        Task {
            await reminder.update(
                enabled: enabled ?? reminder.isEnabled,
                weekday: weekday ?? reminder.weekday,
                minuteOfDay: minute ?? reminder.minuteOfDay
            )
        }
    }
}

/// What the coach has cost so far, from the record kept of every API call.
private struct SpendingSection: View {
    @Query private var charges: [CoachCharge]

    var body: some View {
        let summary = SpendSummary(charges.map(\.spendEntry), now: .now, calendar: .current)
        Section {
            LabeledContent("Total", value: money(summary.total))
            LabeledContent("This month", value: money(summary.thisMonth))
            LabeledContent("This week", value: money(summary.thisWeek))
            LabeledContent("Average per session", value: summary.averagePerSession.map(money) ?? "–")
        } header: {
            Text("Coach spending")
        } footer: {
            Text(
                "\(summary.sessions) coaching session\(summary.sessions == 1 ? "" : "s") so far. A session is one review, one generated plan or one whole conversation. Weeks run Sunday to Saturday. These are estimates from token counts at list prices; the Anthropic Console has the billed amounts."
            )
        }
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
