import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Goal, dates and availability in; a draft plan from the coach out.
struct PlanGeneratorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \Goal.targetDay) private var goals: [Goal]
    @Query(sort: \AthleteProfile.createdAt) private var profiles: [AthleteProfile]
    @Query(sort: \CompletedWorkout.start, order: .reverse) private var workouts: [CompletedWorkout]

    /// Called with the draft once it has been generated.
    let onDraft: (TrainingPlan) -> Void

    @State private var goalID: UUID?
    @State private var startDate = Calendar.current.startOfDay(for: .now)
    @State private var endDate =
        Calendar.current.date(byAdding: .weekOfYear, value: 12, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var hours: [Double] = Array(repeating: 1, count: 7)
    @State private var sports: Set<Sport> = [.swim, .bike, .run, .strength]
    @State private var notes = ""
    @State private var didLoad = false
    @State private var didCopy = false

    private var coach: CoachSession { environment.coach }
    private var goal: Goal? { goals.first { $0.uuid == goalID } }
    private var activeGoals: [Goal] { goals.filter { $0.status == .active } }
    private var isValid: Bool { startDate <= endDate && hours.contains { $0 > 0 } && !sports.isEmpty }

    private var request: PlanRequest {
        PlanRequest(start: startDate, end: endDate, goalTitle: goal?.title, goalDate: goal?.targetDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch coach.state {
                case .running(let summary):
                    progress(summary)
                default:
                    inputs
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Generate Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(coach.isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        Task { await generate() }
                    }
                    .disabled(!isValid || !coach.hasKey || coach.isRunning)
                }
            }
            .interactiveDismissDisabled(coach.isRunning)
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
    }

    @ViewBuilder
    private func progress(_ summary: String) -> some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(
                    coach.plannedSessionCount > 0
                        ? "Planned \(coach.plannedSessionCount) sessions so far…" : "Reading your training history…"
                )
                .foregroundStyle(.secondary)
            }
            if !summary.isEmpty {
                Text(summary)
            }
        } footer: {
            Text("This usually takes a couple of minutes. Keep the app open.")
        }
    }

    @ViewBuilder
    private var inputs: some View {
        if case .failed(let error) = coach.state {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error.title)
                        Text(error.explanation).font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }

        Section {
            Picker("Goal", selection: $goalID) {
                Text("None").tag(UUID?.none)
                ForEach(activeGoals) { Text($0.title).tag(UUID?.some($0.uuid)) }
            }
            DatePicker("Starts", selection: $startDate, displayedComponents: .date)
            DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date)
        } header: {
            Text("What to plan for")
        } footer: {
            Text(
                "To redo part of your current plan, start from the date you want changed. Accepting the draft replaces your existing sessions from that date on."
            )
        }
        .onChange(of: goalID) {
            if let date = goal?.targetDate, date >= startDate { endDate = date }
        }

        Section {
            ForEach(0..<7, id: \.self) { index in
                Stepper(value: $hours[index], in: 0...8, step: 0.5) {
                    LabeledContent(
                        Self.weekdays[index], value: hours[index] == 0 ? "Day off" : "\(hours[index].formatted()) h")
                }
            }
        } header: {
            Text("Time available")
        } footer: {
            Text("\(hours.reduce(0, +).formatted()) hours a week. Nothing is planned on a day off.")
        }

        Section("Sports") {
            ForEach(Sport.allCases.filter { $0 != .other }) { sport in
                Toggle(
                    isOn: Binding(
                        get: { sports.contains(sport) },
                        set: { isOn in if isOn { sports.insert(sport) } else { sports.remove(sport) } }
                    )
                ) {
                    Label(sport.displayName, systemImage: sport.symbolName)
                }
            }
        }

        Section {
            TextField("Injuries, constraints, preferences", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("Notes for the coach")
        }

        Section {
            if fitness.sessions == 0 {
                Text("No workouts in the last four weeks. The plan will start conservatively.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Training per week", value: Format.duration(fitness.seconds / 4))
                LabeledContent(
                    "Sessions per week",
                    value: (Double(fitness.sessions) / 4).formatted(.number.precision(.fractionLength(0...1))))
                LabeledContent("Load per week", value: Format.load(fitness.load / 4))
                if let longest = fitness.longestRun {
                    LabeledContent("Longest run", value: Format.duration(longest))
                }
                if let longest = fitness.longestRide {
                    LabeledContent("Longest ride", value: Format.duration(longest))
                }
            }
        } header: {
            Text("Current fitness · last 4 weeks")
        } footer: {
            Text(
                "Worked out from your workout history. The coach also sees each workout, your recovery data and load trend."
            )
        }

        Section {
            Button {
                copyForClaude()
            } label: {
                Label(didCopy ? "Copied" : "Copy for Claude Instead", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(!isValid)
        } footer: {
            if coach.hasKey {
                Text(
                    "Generating a plan typically costs 30 to 60 cents on the default model. The result is a draft: nothing in your plan changes until you accept it."
                )
            } else {
                Text(
                    "Add an Anthropic API key in Settings to generate a plan here. Copy for Claude needs no key, but the plan it writes has to be entered by hand."
                )
            }
        }
    }

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private var fitness: (sessions: Int, seconds: Double, load: Double, longestRun: Double?, longestRide: Double?) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -28, to: .now) ?? .now
        let recent = workouts.filter { $0.isPrimary && $0.start >= cutoff }
        return (
            recent.count,
            recent.reduce(0) { $0 + $1.durationSeconds },
            recent.reduce(0) { $0 + ($1.load ?? 0) },
            recent.filter { $0.sport == .run }.map(\.durationSeconds).max(),
            recent.filter { $0.sport == .bike }.map(\.durationSeconds).max()
        )
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        coach.dismissError()
        if let profile = profiles.first {
            if profile.availabilityHours.count == 7 { hours = profile.availabilityHours }
            let enabled = Set(profile.enabledSports).subtracting([.other])
            if !enabled.isEmpty { sports = enabled }
            notes = profile.coachNotes
        }
        let upcoming =
            activeGoals
            .filter { ($0.targetDate ?? .distantPast) > startDate }
            .min { ($0.priority, $0.targetDate ?? .distantFuture) < ($1.priority, $1.targetDate ?? .distantFuture) }
        if let upcoming, let date = upcoming.targetDate {
            goalID = upcoming.uuid
            endDate = date
        }
    }

    /// What was entered is the athlete's standing availability, so it is kept on the profile.
    private func saveProfile() {
        let profile: AthleteProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = AthleteProfile()
            context.insert(profile)
        }
        profile.availabilityHours = hours
        profile.enabledSports = Sport.allCases.filter(sports.contains)
        profile.coachNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try? context.save()
    }

    private func generate() async {
        saveProfile()
        guard let draft = await coach.generatePlan(request, goal: goal, in: context) else { return }
        dismiss()
        onDraft(draft)
    }

    private func copyForClaude() {
        saveProfile()
        guard let built = try? CoachPayloadBuilder.build(in: context, trigger: .planGeneration, planRequest: request)
        else { return }
        let text = CoachPayloadBuilder.planExportText(for: built)
        #if os(iOS)
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]], options: [.expirationDate: Date().addingTimeInterval(600)])
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        didCopy = true
    }
}

/// A generated plan before it is accepted: the coach's summary, and the same week and
/// month views as the real plan so every session can be edited first.
struct DraftPlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \TrainingPlan.startDay) private var allPlans: [TrainingPlan]

    let draft: TrainingPlan
    /// Called with the plan once it has been accepted.
    let onAccept: (TrainingPlan) -> Void

    @State private var mode: PlanMode = .week
    @State private var anchor: Date
    @State private var sheet: PlanSheet?
    @State private var confirmingAccept = false
    @State private var confirmingDiscard = false
    @State private var showsSummary = true

    init(draft: TrainingPlan, onAccept: @escaping (TrainingPlan) -> Void) {
        self.draft = draft
        self.onAccept = onAccept
        _anchor = State(initialValue: draft.startDate)
    }

    /// Whether accepting would remove sessions from a plan already in use.
    private var replacesExisting: Bool {
        allPlans.contains { !$0.isDraft && $0.endDate >= draft.startDate }
    }

    private var totals: String {
        let sessions = draft.workouts ?? []
        let weeks = max(
            1, ((Calendar.current.dateComponents([.day], from: draft.startDate, to: draft.endDate).day ?? 0) + 1) / 7)
        return "\(sessions.count) sessions over \(weeks) weeks"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { showsSummary.toggle() }
                } label: {
                    HStack {
                        Text(totals).font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: showsSummary ? "chevron.up" : "chevron.down").font(.caption)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(totals). \(showsSummary ? "Hide" : "Show") the coach's summary")
                if showsSummary, !draft.coachSummary.isEmpty {
                    let summary = Text(draft.coachSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Short summaries take only the room they need; long ones scroll.
                    ViewThatFits(in: .vertical) {
                        summary
                        ScrollView { summary }
                    }
                    .frame(maxHeight: 170, alignment: .top)
                }
            }
            .padding(12)
            .background(.cardBackground, in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)

            Picker("View", selection: $mode) {
                ForEach(PlanMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .week: PlanWeekView(plan: draft, anchor: $anchor, sheet: $sheet)
            case .month: PlanMonthView(plan: draft, anchor: $anchor, sheet: $sheet)
            }
        }
        .background(.pageBackground)
        .navigationTitle("Draft Plan")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Accept") {
                    if replacesExisting { confirmingAccept = true } else { accept() }
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Discard", role: .destructive) { confirmingDiscard = true }
            }
        }
        .confirmationDialog(
            "Replace your current plan from \(draft.startDate.formatted(date: .abbreviated, time: .omitted))?",
            isPresented: $confirmingAccept,
            titleVisibility: .visible
        ) {
            Button("Accept and Replace") { accept() }
        } message: {
            Text(
                "Sessions already planned on or after that date are replaced. Earlier sessions carry over, and your completed workouts are kept."
            )
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Draft", role: .destructive) {
                try? PlanReconciler.discardDraft(draft, in: context)
                dismiss()
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newWorkout(let date):
                PlannedWorkoutEditor(plan: draft, workout: nil, date: date)
            case .editWorkout(let workout):
                PlannedWorkoutEditor(plan: draft, workout: workout, date: workout.date)
            default:
                EmptyView()
            }
        }
    }

    private func accept() {
        guard (try? PlanReconciler.acceptDraft(draft, in: context)) != nil else { return }
        onAccept(draft)
        environment.reconcilePlan()
        dismiss()
    }
}
