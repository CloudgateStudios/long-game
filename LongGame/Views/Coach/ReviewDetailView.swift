import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

struct ReviewDetailView: View {
    let review: CoachReview
    @State private var renaming: NamedSession?

    private var suggestions: [PlanSuggestion] {
        (review.suggestions ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            Section {
                Text(review.assessment)
            } header: {
                Text("Assessment")
            } footer: {
                Text("The coach is a training assistant, not a medical service. For pain, illness or readings that worry you, see a professional.")
            }

            if !review.flags.isEmpty {
                Section("Flags") {
                    ForEach(review.flags, id: \.self) { flag in
                        Label {
                            Text(flag)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }

            if suggestions.isEmpty {
                Section("Suggestions") {
                    Text("No changes suggested.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.element.uuid) { index, suggestion in
                    Section(index == 0 ? "Suggestions" : "") {
                        SuggestionCard(suggestion: suggestion)
                    }
                }
            }

            Section("About this review") {
                LabeledContent("When", value: review.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Covers", value: (review.periodStart..<review.periodEnd).formatted(.interval.day().month(.abbreviated)))
                LabeledContent("Model", value: CoachConfiguration.model(review.model)?.name ?? review.model)
                if let input = review.inputTokens, let output = review.outputTokens {
                    LabeledContent("Tokens", value: "\(input.formatted()) in · \(output.formatted()) out")
                    if let cost = CoachConfiguration.cost(model: review.model, inputTokens: input, outputTokens: output) {
                        LabeledContent("Estimated cost", value: cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                    }
                }
                NavigationLink("What Was Sent") {
                    PayloadView(json: review.payloadJSON)
                }
            }
        }
        .readableWidth()
        .navigationTitle(review.displayTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename", systemImage: "pencil") { renaming = .review(review) }
            }
        }
        .renameSession($renaming)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One proposed change as a before/after comparison with Accept and Reject. Nothing
/// changes in the plan until Accept is pressed.
struct SuggestionCard: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    let suggestion: PlanSuggestion
    @State private var failure: String?

    private var proposal: CoachSuggestion? { SuggestionApplier.proposal(of: suggestion) }

    private struct Row: Identifiable {
        let field: String
        let before: String?
        let after: String?
        var id: String { field }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(headline, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if suggestion.status != .pending {
                    Text(suggestion.status == .accepted ? "Accepted" : "Rejected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(suggestion.status == .accepted ? .green : .secondary)
                }
            }

            if suggestion.action == .remove {
                Text(target).strikethrough().foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(rows) { row in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(row.field).font(.caption).foregroundStyle(.secondary)
                            if let before = row.before {
                                Text(before).strikethrough().foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityLabel("changes to")
                            }
                            Text(row.after ?? "–").gridCellColumns(row.before == nil ? 3 : 1)
                        }
                    }
                }
                .font(.subheadline)
            }

            Text(suggestion.rationale).font(.subheadline).foregroundStyle(.secondary)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if suggestion.status == .pending {
                HStack {
                    Button("Accept", action: accept)
                        .buttonStyle(.borderedProminent)
                    Button("Reject") {
                        try? SuggestionApplier.reject(suggestion, in: context)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch suggestion.action {
        case .modify: "pencil"
        case .move: "calendar"
        case .remove: "minus.circle"
        case .add: "plus.circle"
        }
    }

    /// The session as it is now, or as it was if it has since changed or gone.
    private var target: String {
        if suggestion.status == .pending, let session = suggestion.targetWorkout {
            return "\(session.date.formatted(.dateTime.weekday().day().month())) · \(Format.title(of: session))"
        }
        // The stored summary starts with an ISO date, which reads better as a weekday.
        let summary = suggestion.targetSummary
        guard let date = SuggestionApplier.date(from: String(summary.prefix(10))) else { return summary }
        let rest = summary.dropFirst(10).drop { $0 == "," || $0 == " " }
        return "\(date.formatted(.dateTime.weekday().day().month())) · \(rest)"
    }

    private var headline: String {
        switch suggestion.action {
        case .modify: "Change \(target)"
        case .move: "Move \(target)"
        case .remove: "Remove a session"
        case .add: "Add a session"
        }
    }

    private func dateText(_ text: String?) -> String? {
        SuggestionApplier.date(from: text)?.formatted(.dateTime.weekday().day().month())
    }

    /// Only the fields the suggestion changes. The "before" column shows live values, so
    /// it is only filled in while the suggestion is still pending.
    private var rows: [Row] {
        guard let proposal else { return [] }
        let current = suggestion.status == .pending ? suggestion.targetWorkout : nil
        let sport = proposal.sport ?? current?.sport ?? .run
        var rows: [Row] = []
        func add(_ field: String, before: String?, after: String?) {
            guard let after else { return }
            rows.append(Row(field: field, before: suggestion.action == .add ? nil : before, after: after))
        }
        add("Date", before: current.map { $0.date.formatted(.dateTime.weekday().day().month()) }, after: dateText(proposal.date))
        add("Sport", before: current?.sport.displayName, after: proposal.sport?.displayName)
        add("Type", before: current?.sessionType.displayName, after: proposal.sessionType?.displayName)
        add("Duration", before: current?.targetDurationSeconds.map(Format.duration), after: proposal.durationMinutes.map { Format.duration($0 * 60) })
        add("Distance",
            before: current.flatMap { session in session.targetDistanceMeters.map { Format.distance($0, sport: session.sport) } },
            after: proposal.distanceKm.map { Format.distance($0 * 1000, sport: sport) })
        add("Intensity", before: current.flatMap { $0.targetIntensity.isEmpty ? nil : $0.targetIntensity }, after: proposal.intensity)
        add("Notes", before: current.flatMap { $0.instructions.isEmpty ? nil : $0.instructions }, after: proposal.instructions)
        return rows
    }

    private func accept() {
        do {
            try SuggestionApplier.accept(suggestion, in: context)
            failure = nil
            // The plan changed, so matching and load need another pass.
            environment.reconcilePlan()
        } catch SuggestionError.sessionGone {
            failure = "That session is no longer in the plan."
        } catch SuggestionError.noPlan {
            failure = "There is no plan to add this to."
        } catch {
            failure = "This suggestion is missing details and cannot be applied."
        }
    }
}
