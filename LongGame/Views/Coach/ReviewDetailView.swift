import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

struct ReviewDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    let review: CoachReview
    @State private var renaming: NamedSession?

    private var pending: [PlanSuggestion] { suggestions.filter { $0.status == .pending } }

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
                Text(
                    "The coach is a training assistant, not a medical service. For pain, illness or readings that worry you, see a professional."
                )
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

            Section {
                if suggestions.isEmpty {
                    Text("No changes suggested.").foregroundStyle(.secondary)
                }
                ForEach(suggestions, id: \.uuid) { suggestion in
                    SuggestionCard(suggestion: suggestion)
                }
            } header: {
                HStack {
                    Text("Suggestions")
                    Spacer()
                    if !suggestions.isEmpty {
                        Text("\(suggestions.count - pending.count) of \(suggestions.count) decided")
                    }
                }
            }

            Section("About this review") {
                LabeledContent("When", value: review.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(
                    "Covers",
                    value: (review.periodStart..<review.periodEnd).formatted(.interval.day().month(.abbreviated)))
                LabeledContent("Model", value: CoachConfiguration.model(review.model)?.name ?? review.model)
                if let input = review.inputTokens, let output = review.outputTokens {
                    LabeledContent("Tokens", value: "\(input.formatted()) in · \(output.formatted()) out")
                    if let cost = CoachConfiguration.cost(model: review.model, inputTokens: input, outputTokens: output)
                    {
                        LabeledContent(
                            "Estimated cost",
                            value: cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                    }
                }
                NavigationLink("What Was Sent") {
                    PayloadView(json: review.payloadJSON)
                }
            }
        }
        .readableWidth()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pending.count > 1 {
                Button(action: acceptAll) {
                    Text("Accept All \(pending.count) Remaining").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
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

extension ReviewDetailView {
    /// Applies every suggestion still pending. One that can no longer be applied is left
    /// pending, where its own Accept explains why.
    fileprivate func acceptAll() {
        withAnimation {
            for suggestion in pending {
                try? SuggestionApplier.accept(suggestion, in: context)
            }
        }
        environment.reconcilePlan()
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
        if suggestion.status == .pending {
            pendingCard
        } else {
            // Decided: one line is enough to say what it was and which way it went.
            HStack(alignment: .firstTextBaseline) {
                Label(headline, systemImage: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Chip(
                    text: suggestion.status == .accepted ? "Accepted" : "Rejected",
                    tint: suggestion.status == .accepted ? .green : .secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(headline, systemImage: symbol)
                .font(.subheadline.weight(.semibold))

            // The reason comes first: it is the argument, the rows below are the detail.
            Text(suggestion.rationale).font(.subheadline)

            if suggestion.action == .remove {
                Text(target).font(.subheadline).strikethrough().foregroundStyle(.secondary)
            } else if !rows.isEmpty {
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

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation { try? SuggestionApplier.reject(suggestion, in: context) }
                } label: {
                    Text("Reject").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button {
                    withAnimation { accept() }
                } label: {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
            // A field the coach restated without changing is not a change.
            guard let after, suggestion.action == .add || before != after else { return }
            rows.append(Row(field: field, before: suggestion.action == .add ? nil : before, after: after))
        }
        add(
            "Date", before: current.map { $0.date.formatted(.dateTime.weekday().day().month()) },
            after: dateText(proposal.date))
        add("Sport", before: current?.sport.displayName, after: proposal.sport?.displayName)
        add("Type", before: current?.sessionType.displayName, after: proposal.sessionType?.displayName)
        add(
            "Duration", before: current?.targetDurationSeconds.map(Format.duration),
            after: proposal.durationMinutes.map { Format.duration($0 * 60) })
        add(
            "Distance",
            before: current.flatMap { session in
                session.targetDistanceMeters.map { Format.distance($0, sport: session.sport) }
            },
            after: proposal.distanceKm.map { Format.distance($0 * 1000, sport: sport) })
        add(
            "Intensity", before: current.flatMap { $0.targetIntensity.isEmpty ? nil : $0.targetIntensity },
            after: proposal.intensity)
        add(
            "Notes", before: current.flatMap { $0.instructions.isEmpty ? nil : $0.instructions },
            after: proposal.instructions)
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
