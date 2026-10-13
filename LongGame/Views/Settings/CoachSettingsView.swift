import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

/// Everything the coach runs on: the API key and model, what it has cost, and the
/// standing notes it is given. The key goes straight to the Keychain and is never shown
/// again once saved.
struct CoachSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \AthleteProfile.createdAt) private var profiles: [AthleteProfile]
    @Query private var charges: [CoachCharge]

    @State private var draft = ""
    @State private var saveFailed = false
    @State private var notes = ""
    @State private var didLoad = false

    private var profile: AthleteProfile? { profiles.first }

    var body: some View {
        @Bindable var coach = environment.coach
        let summary = SpendSummary(charges.map(\.spendEntry), now: .now, calendar: .current)
        Form {
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
            } footer: {
                if saveFailed {
                    Text("The key could not be saved to the Keychain.")
                } else {
                    Text(
                        "The key is stored in your iCloud Keychain, so your other devices get it too. API use is billed by Anthropic separately from a Claude subscription."
                    )
                }
            }

            Section {
                TextField("Injuries, constraints, preferences", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Notes for the coach")
            } footer: {
                Text(
                    "Sent with every review. For example: \"left knee is sore after long descents\" or \"no swimming on Fridays\"."
                )
            }

            Section {
                LabeledContent("This week", value: SpendSummary.money(summary.thisWeek))
                LabeledContent("This month", value: SpendSummary.money(summary.thisMonth))
                LabeledContent("Total", value: SpendSummary.money(summary.total))
                LabeledContent(
                    "Average per session", value: summary.averagePerSession.map(SpendSummary.money) ?? "–")
            } header: {
                Text("Spending")
            } footer: {
                Text(
                    "\(summary.sessions) coaching session\(summary.sessions == 1 ? "" : "s") so far. A session is one review, one generated plan or one whole conversation. Weeks run Sunday to Saturday. These are estimates from token counts at list prices; the Anthropic Console has the billed amounts."
                )
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .navigationTitle("Coach")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: load)
        // Notes are saved once on the way out rather than on every keystroke.
        .onDisappear { environment.saveChanges() }
        .onChange(of: notes) {
            if didLoad { profile?.coachNotes = notes }
        }
    }

    private func load() {
        guard !didLoad else { return }
        if profile == nil { context.insert(AthleteProfile()) }
        notes = profile?.coachNotes ?? ""
        didLoad = true
    }
}

extension SpendSummary {
    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
