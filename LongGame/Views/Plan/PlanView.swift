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
    @State private var exporting: TrainingPlan?
    /// The draft whose banner was put off; it stays reachable from the options menu.
    @AppStorage("dismissedDraftID") private var dismissedDraftID = ""

    private var plans: [TrainingPlan] { allPlans.filter { !$0.isDraft } }
    private var draft: TrainingPlan? { allPlans.first(where: \.isDraft) }

    /// The chosen plan, else the one covering today, else the most recent.
    private var plan: TrainingPlan? {
        plans.first { $0.uuid.uuidString == selectedPlanID }
            ?? plans.first { $0.startDay <= .now && .now <= $0.endDay }
            ?? plans.last
    }

    var body: some View {
        Group {
            if let plan {
                VStack(spacing: 0) {
                    if let draft, draft.uuid.uuidString != dismissedDraftID {
                        DraftBanner(
                            review: { reviewingDraft = draft },
                            later: { withAnimation { dismissedDraftID = draft.uuid.uuidString } })
                    }
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if plan != nil {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(PlanMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            if let plan {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Add to \(anchor.formatted(.dateTime.weekday(.wide).day()))", systemImage: "plus") {
                        Button("Session", systemImage: "figure.run") { sheet = .newWorkout(anchor) }
                        DayMarkerButtons(plan: plan, day: anchor)
                    } primaryAction: {
                        sheet = .newWorkout(anchor)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("Plan Options", systemImage: "ellipsis.circle") {
                    if let draft {
                        Button("Review Draft Plan", systemImage: "sparkles") { reviewingDraft = draft }
                    }
                    if let plan {
                        Button("Edit Plan", systemImage: "pencil") { sheet = .editPlan(plan) }
                        ShareLink(
                            item: PlanCalendarDocument(plan: plan),
                            preview: SharePreview(plan.name, image: Image(systemName: "calendar"))
                        ) {
                            Label("Share Calendar PDF", systemImage: "square.and.arrow.up")
                        }
                        #if os(macOS)
                        Button("Save Calendar as PDF…", systemImage: "arrow.down.doc") { exporting = plan }
                        #endif
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
                if let plan = workout.plan { PlannedWorkoutEditor(plan: plan, workout: workout, date: workout.day) }
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
        #if os(macOS)
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            item: exporting.map { PlanCalendarDocument(plan: $0) },
            contentTypes: [.pdf],
            defaultFilename: exporting.map { PlanCalendarDocument(plan: $0).fileName }
        ) { _ in }
        #endif
        .navigationDestination(item: $interview) { conversation in
            CoachChatView(conversation: conversation)
        }
        .navigationDestination(item: $reviewingDraft) { draft in
            DraftPlanView(draft: draft) { selectedPlanID = $0.uuid.uuidString }
        }
    }
}

private struct DraftBanner: View {
    let review: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: review) {
                HStack {
                    Label("Draft plan ready to review", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button("Later", systemImage: "xmark", action: later)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(.rect)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
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
        hasher.combine(workout.day)
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

/// One planned session; tap to open it, drag or use the menu to move it. A rest or flex
/// day has nothing to read, so it opens straight in the editor.
struct PlannedWorkoutRow: View {
    @Environment(\.modelContext) private var context
    let workout: PlannedWorkout
    @Binding var sheet: PlanSheet?

    var body: some View {
        Group {
            if workout.isDayMarker {
                Button {
                    sheet = .editWorkout(workout)
                } label: {
                    label
                }
            } else {
                NavigationLink {
                    PlannedWorkoutDetailView(workout: workout)
                } label: {
                    label
                }
            }
        }
        .buttonStyle(.plain)
        .draggable(workout.uuid.uuidString)
        .contextMenu {
            Button("Edit", systemImage: "pencil") { sheet = .editWorkout(workout) }
            Button("Move to Previous Day", systemImage: "arrow.up") { workout.move(byDays: -1) }
            Button("Move to Next Day", systemImage: "arrow.down") { workout.move(byDays: 1) }
            Button("Duplicate to Next Week", systemImage: "plus.square.on.square") {
                workout.duplicate(daysLater: 7)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                context.delete(workout)
                try? context.save()
            }
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.symbolName)
                .foregroundStyle(workout.tintColor)
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
            StatusChip(workout: workout)
        }
        .contentShape(.rect)
    }
}

/// The "+" on a day: a full session, or a one-tap rest or flex day.
struct AddToDayMenu: View {
    let plan: TrainingPlan
    let day: Date
    @Binding var sheet: PlanSheet?

    var body: some View {
        Menu("Add to \(day.formatted(.dateTime.weekday(.wide)))", systemImage: "plus") {
            Button("Session", systemImage: "figure.run") { sheet = .newWorkout(day) }
            DayMarkerButtons(plan: plan, day: day)
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct DayMarkerButtons: View {
    let plan: TrainingPlan
    let day: Date

    var body: some View {
        ForEach([SessionType.rest, .flex]) { type in
            Button("\(type.displayName) Day", systemImage: type.dayMarkerSymbolName ?? "calendar") {
                withAnimation { plan.markDay(day, as: type) }
            }
        }
    }
}

extension TrainingPlan {
    /// Marks `date` as a rest or flex day. A day already marked changes kind rather than
    /// gaining a second marker; sessions planned on it are left for the user to deal with.
    func markDay(_ date: Date, as type: SessionType) {
        if let existing = workouts(on: date).first(where: \.isDayMarker) {
            existing.sessionType = type
        } else {
            let marker = PlannedWorkout(date: Calendar.current.startOfDay(for: date), sport: .other, sessionType: type)
            modelContext?.insert(marker)
            marker.plan = self
        }
        try? modelContext?.save()
    }

    /// Moves the session with this identifier (from a drag) to `date`.
    func moveWorkout(withID id: String, to date: Date) -> Bool {
        guard let workout = (workouts ?? []).first(where: { $0.uuid.uuidString == id }) else { return false }
        workout.day = Calendar.current.startOfDay(for: date)
        try? workout.modelContext?.save()
        return true
    }
}

extension PlanCalendarDocument {
    /// Captures what the printed calendar shows of `plan`.
    init(plan: TrainingPlan, calendar: Calendar = .current) {
        self.init(
            name: plan.name,
            start: calendar.startOfDay(for: plan.startDay),
            end: calendar.startOfDay(for: plan.endDay),
            goalTitle: plan.goal?.title,
            goalDate: plan.goal?.targetDay,
            phases: plan.sortedPhases.map {
                Phase(
                    name: $0.kind.displayName,
                    start: calendar.startOfDay(for: $0.startDay),
                    end: calendar.startOfDay(for: $0.endDay))
            }
        )
        let byDay = Dictionary(grouping: plan.workouts ?? []) { calendar.startOfDay(for: $0.day) }
        sessions = byDay.mapValues { workouts in
            workouts
                .sorted(by: PlannedWorkout.inDayOrder)
                .map {
                    Session(
                        id: $0.uuid,
                        symbolName: $0.symbolName,
                        title: Format.title(of: $0),
                        targets: Format.targets(of: $0),
                        instructions: $0.instructions)
                }
        }
    }
}
