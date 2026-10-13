import Analysis
import Models
import SwiftData
import SwiftUI

/// The pages behind the rows of Settings.
enum SettingsPage: Hashable {
    case profile, coach, reminder, health, iCloud
}

/// Opens Settings, on one of its pages if given: a sheet on iPhone and iPad, the
/// Settings window on Mac.
struct OpenSettingsButton<Label: View>: View {
    var page: SettingsPage?
    @ViewBuilder var label: Label

    @Environment(AppEnvironment.self) private var environment
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        Button {
            environment.settingsPath = page.map { [$0] } ?? []
            #if os(macOS)
            openSettings()
            #else
            environment.isShowingSettings = true
            #endif
        } label: {
            label
        }
    }
}

/// Settings in a navigation stack of its own.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var environment = environment
        NavigationStack(path: $environment.settingsPath) {
            SettingsView()
                .navigationTitle("Settings")
                .navigationDestination(for: SettingsPage.self) { page in
                    switch page {
                    case .profile: ProfileView()
                    case .coach: CoachSettingsView()
                    case .reminder: ReminderSettingsView()
                    case .health: HealthSettingsView()
                    case .iCloud: CloudSettingsView()
                    }
                }
                #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
                #endif
        }
    }
}

/// One row per page, each showing where things stand so most visits end here.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \AthleteProfile.createdAt) private var profiles: [AthleteProfile]
    @Query private var charges: [CoachCharge]

    @State private var zones = ResolvedZones()

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsPage.profile) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Athlete Profile")
                            Text(profileText).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "heart.text.square")
                    }
                }
            }

            Section {
                row("Coach", systemImage: "text.bubble", value: coachText, page: .coach)
                row(
                    "Weekly Review", systemImage: "bell", value: reminderText, warns: environment.reminder.isDenied,
                    page: .reminder)
            }

            Section {
                row(
                    "Health Data", systemImage: "heart", value: environment.healthStatusText,
                    warns: environment.healthState == .failed, page: .health)
                row(
                    "iCloud", systemImage: "icloud", value: environment.cloudSummaryText,
                    warns: environment.cloudNeedsAttention, page: .iCloud)
            } footer: {
                Text("Long Game \(versionText)")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        // Runs again on the way back from a page, so the profile row keeps up with edits.
        .onAppear {
            zones = (try? LoadRecalculator.resolveZones(in: context)) ?? ResolvedZones()
        }
    }

    private func row(
        _ title: String, systemImage: String, value: String, warns: Bool = false, page: SettingsPage
    ) -> some View {
        NavigationLink(value: page) {
            LabeledContent {
                HStack(spacing: 4) {
                    if warns {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(value)
                }
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private var profileText: String {
        var parts: [String] = []
        if let maxHR = zones.maxHR { parts.append("Max \(Format.load(maxHR)) bpm") }
        if let ftp = profiles.first?.ftpWatts { parts.append("FTP \(Format.load(ftp)) W") }
        return parts.isEmpty ? "Heart rate, zones and FTP" : parts.joined(separator: " · ")
    }

    private var coachText: String {
        guard environment.coach.hasKey else { return "No API key" }
        let summary = SpendSummary(charges.map(\.spendEntry), now: .now, calendar: .current)
        return "\(SpendSummary.money(summary.thisMonth)) this month"
    }

    private var reminderText: String {
        let reminder = environment.reminder
        if reminder.isDenied { return "Notifications off" }
        guard reminder.isEnabled else { return "Off" }
        let day = Calendar.current.shortWeekdaySymbols[reminder.weekday - 1]
        return "\(day) \(reminder.time.formatted(date: .omitted, time: .shortened))"
    }

    /// Version and build number of the running app, as "0.1.0 (3)".
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}
