import Analysis
import Models
import SwiftData
import SwiftUI

enum PlanMode: String, CaseIterable, Identifiable {
    case week, month

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum PlanSheet: Identifiable {
    case newWorkout(Date)
    case editWorkout(PlannedWorkout)
    case newPlan
    case editPlan(TrainingPlan)
    case goals
    case generate

    var id: String {
        switch self {
        case .newWorkout(let date): "new-workout-\(date.timeIntervalSinceReferenceDate)"
        case .editWorkout(let workout): "workout-\(workout.uuid)"
        case .newPlan: "new-plan"
        case .editPlan(let plan): "plan-\(plan.uuid)"
        case .goals: "goals"
        case .generate: "generate"
        }
    }
}

struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \TrainingPlan.startDate) private var allPlans: [TrainingPlan]
    @State private var reviewingDraft: TrainingPlan?
    @State private var interview: CoachConversation?
    @AppStorage("selectedPlanID") private var selectedPlanID = ""
    @AppStorage("planMode") private var mode: PlanMode = .week
    @State private var anchor = Date()
    @State private var sheet: PlanSheet?

    private var plans: [TrainingPlan] { allPlans.filter { !$0.isDraft } }
    private var draft: TrainingPlan? { allPlans.first(where: \.isDraft) }

    /// The chosen plan, else the one covering today, else the most recent.
    private var plan: TrainingPlan? {
        plans.first { $0.uuid.uuidString == selectedPlanID }
            ?? plans.first { $0.startDate <= .now && .now <= $0.endDate }
            ?? plans.last
    }

    var body: some View {
        Group {
            if let plan {
                VStack(spacing: 0) {
                    if let draft {
                        DraftBanner(draft: draft) { reviewingDraft = draft }
                    }
                    Picker("View", selection: $mode) {
                        ForEach(PlanMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    switch mode {
                    case .week: PlanWeekView(plan: plan, anchor: $anchor, sheet: $sheet)
                    case .month: PlanMonthView(plan: plan, anchor: $anchor, sheet: $sheet)
                    }
                }
                .background(.pageBackground)
            } else {
                ContentUnavailableView {
                    Label("No plan yet", systemImage: "calendar.badge.plus")
                } description: {
                    Text(
                        environment.coach.hasKey
                            ? "The coach can interview you and draft a plan, or you can build one yourself."
                            : "Create a training plan toward your goal. Add an API key in Settings to have the coach interview you and draft one."
                    )
                } actions: {
                    if let draft {
                        Button("Review Draft Plan") { reviewingDraft = draft }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Plan with the Coach", action: startInterview)
                            .buttonStyle(.borderedProminent)
                            .disabled(!environment.coach.canChat)
                        Button("Generate from a Form") { sheet = .generate }
                    }
                    Button("Create by Hand") { sheet = .newPlan }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Plan Options", systemImage: "ellipsis.circle") {
                    if let plan {
                        Button("Add Session", systemImage: "plus") { sheet = .newWorkout(anchor) }
                        Button("Edit Plan", systemImage: "pencil") { sheet = .editPlan(plan) }
                    }
                    if plans.count > 1 {
                        Picker(
                            "Plan",
                            selection: Binding(
                                get: { plan?.uuid.uuidString ?? "" },
                                set: { selectedPlanID = $0 }
                            )
                        ) {
                            ForEach(plans) { Text($0.name).tag($0.uuid.uuidString) }
                        }
                    }
                    Divider()
                    Button(
                        "Plan with the Coach", systemImage: "bubble.left.and.text.bubble.right", action: startInterview
                    )
                    .disabled(!environment.coach.canChat)
                    Button("Generate Plan from a Form", systemImage: "sparkles") { sheet = .generate }
                    Button("New Plan", systemImage: "calendar.badge.plus") { sheet = .newPlan }
                    Button("Goals", systemImage: "flag.checkered") { sheet = .goals }
                }
            }
        }
        // Any edit that could change a match or a status re-runs matching.
        .task(id: plan.map(matchingSignature)) {
            environment.reconcilePlan()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newWorkout(let date):
                if let plan { PlannedWorkoutEditor(plan: plan, workout: nil, date: date) }
            case .editWorkout(let workout):
                if let plan = workout.plan { PlannedWorkoutEditor(plan: plan, workout: workout, date: workout.date) }
            case .newPlan:
                PlanEditor(plan: nil) { selectedPlanID = $0.uuid.uuidString }
            case .editPlan(let plan):
                PlanEditor(plan: plan) { _ in }
            case .goals:
                GoalsView()
            case .generate:
                PlanGeneratorView { reviewingDraft = $0 }
            }
        }
        .navigationDestination(item: $interview) { conversation in
            CoachChatView(conversation: conversation)
        }
        .navigationDestination(item: $reviewingDraft) { draft in
            DraftPlanView(draft: draft) { selectedPlanID = $0.uuid.uuidString }
        }
    }
}

private struct DraftBanner: View {
    let draft: TrainingPlan
    let review: () -> Void

    var body: some View {
        Button(action: review) {
            HStack {
                Label("Draft plan ready to review", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// Changes whenever something matching depends on does. Statuses are left out, so the
/// reconciler's own writes do not trigger another pass.
private func matchingSignature(_ plan: TrainingPlan) -> Int {
    var hasher = Hasher()
    for workout in (plan.workouts ?? []).sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
        hasher.combine(workout.uuid)
        hasher.combine(workout.date)
        hasher.combine(workout.sportRaw)
        hasher.combine(workout.sessionTypeRaw)
        hasher.combine(workout.targetDurationSeconds)
        hasher.combine(workout.targetDistanceMeters)
        hasher.combine(workout.isManualMatch)
        hasher.combine(workout.matchedWorkout?.externalID)
    }
    return hasher.finalize()
}

extension PlanView {
    /// Opens a conversation in which the coach asks its questions and then drafts a plan.
    /// An unfinished interview is picked up rather than started again.
    fileprivate func startInterview() {
        let existing = try? context.fetch(
            FetchDescriptor<CoachConversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        .first { $0.kind == .interview && $0.draftPlanID == nil }
        if let existing {
            interview = existing
        } else {
            let conversation = CoachConversation(kind: .interview)
            context.insert(conversation)
            interview = conversation
        }
    }
}

/// One planned session; tap to edit, drag or use the menu to move it.
struct PlannedWorkoutRow: View {
    @Environment(\.modelContext) private var context
    let workout: PlannedWorkout
    @Binding var sheet: PlanSheet?

    var body: some View {
        Button {
            sheet = .editWorkout(workout)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: workout.sessionType == .rest ? "moon.zzz" : workout.sport.symbolName)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.title(of: workout)).foregroundStyle(.primary)
                    let targets = Format.targets(of: workout)
                    if !targets.isEmpty {
                        Text(targets).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let structure = workout.structure {
                        WorkoutProfileChart(segments: structure.profile(sport: workout.sport), isCompact: true)
                            .frame(maxWidth: 220)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if let symbol = workout.status.symbolName {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: symbol).foregroundStyle(workout.status.color)
                        if let ratio = workout.complianceRatio {
                            Text(Format.percent(ratio)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(statusDescription)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .draggable(workout.uuid.uuidString)
        .contextMenu {
            Button("Edit", systemImage: "pencil") { sheet = .editWorkout(workout) }
            Button("Move to Previous Day", systemImage: "arrow.up") { move(by: -1) }
            Button("Move to Next Day", systemImage: "arrow.down") { move(by: 1) }
            Button("Duplicate to Next Week", systemImage: "plus.square.on.square") { duplicate(daysLater: 7) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                context.delete(workout)
                try? context.save()
            }
        }
    }

    private var statusDescription: String {
        guard let ratio = workout.complianceRatio else { return workout.status.label }
        return "\(workout.status.label), \(Format.percent(ratio)) of target"
    }

    private func move(by days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: workout.date) else { return }
        withAnimation { workout.date = date }
        try? context.save()
    }

    private func duplicate(daysLater days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: workout.date) else { return }
        let copy = PlannedWorkout(
            date: date,
            sport: workout.sport,
            sessionType: workout.sessionType,
            targetDurationSeconds: workout.targetDurationSeconds,
            targetDistanceMeters: workout.targetDistanceMeters,
            targetIntensity: workout.targetIntensity,
            instructions: workout.instructions
        )
        context.insert(copy)
        copy.plan = workout.plan
        try? context.save()
    }
}

extension TrainingPlan {
    /// Moves the session with this identifier (from a drag) to `date`.
    func moveWorkout(withID id: String, to date: Date) -> Bool {
        guard let workout = (workouts ?? []).first(where: { $0.uuid.uuidString == id }) else { return false }
        workout.date = Calendar.current.startOfDay(for: date)
        try? workout.modelContext?.save()
        return true
    }
}
