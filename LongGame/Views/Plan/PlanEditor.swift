import Analysis
import Models
import SwiftData
import SwiftUI

/// Creates a plan (when `plan` is nil) or edits its name, dates, goal and phases.
struct PlanEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \Goal.targetDate) private var goals: [Goal]

    let plan: TrainingPlan?
    let onSave: (TrainingPlan) -> Void

    private struct PhaseDraft: Identifiable {
        let id = UUID()
        var kind: PlanPhaseKind
        var start: Date
        var end: Date
    }

    @State private var name: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var goalID: UUID?
    @State private var phases: [PhaseDraft]
    @State private var didApplyDefaults = false
    @State private var confirmingDelete = false

    init(plan: TrainingPlan?, onSave: @escaping (TrainingPlan) -> Void) {
        self.plan = plan
        self.onSave = onSave
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        _name = State(initialValue: plan?.name ?? "")
        _startDate = State(initialValue: plan?.startDate ?? weekStart)
        _endDate = State(initialValue: plan?.endDate ?? calendar.date(byAdding: .weekOfYear, value: 12, to: weekStart) ?? weekStart)
        _goalID = State(initialValue: plan?.goal?.uuid)
        _phases = State(initialValue: (plan?.sortedPhases ?? []).map {
            PhaseDraft(kind: $0.kind, start: $0.startDate, end: $0.endDate)
        })
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && startDate <= endDate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Goal", selection: $goalID) {
                        Text("None").tag(UUID?.none)
                        ForEach(goals) { Text($0.title).tag(UUID?.some($0.uuid)) }
                    }
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date)
                }

                Section("Phases") {
                    ForEach($phases) { $phase in
                        VStack(alignment: .leading) {
                            Picker("Phase", selection: $phase.kind) {
                                ForEach(PlanPhaseKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            DatePicker("From", selection: $phase.start, displayedComponents: .date)
                            DatePicker("To", selection: $phase.end, in: phase.start..., displayedComponents: .date)
                        }
                    }
                    .onDelete { phases.remove(atOffsets: $0) }

                    Button("Add Phase", systemImage: "plus") {
                        let start = phases.last.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0.end) } ?? startDate
                        phases.append(PhaseDraft(kind: .base, start: start, end: max(start, endDate)))
                    }
                    Button("Suggest Phases", systemImage: "wand.and.stars", action: suggestPhases)
                }

                if plan != nil {
                    Section {
                        Button("Delete Plan", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(plan == nil ? "New Plan" : "Edit Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
            .confirmationDialog("Delete this plan and all its sessions?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Plan", role: .destructive) {
                    if let plan { context.delete(plan) }
                    environment.reconcilePlan()
                    dismiss()
                }
            }
            .onAppear(perform: applyDefaults)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    /// A new plan starts out aimed at the top-priority upcoming goal.
    private func applyDefaults() {
        guard plan == nil, !didApplyDefaults else { return }
        didApplyDefaults = true
        let upcoming = goals
            .filter { $0.status == .active && ($0.targetDate ?? .distantPast) > startDate }
            .min { ($0.priority, $0.targetDate ?? .distantFuture) < ($1.priority, $1.targetDate ?? .distantFuture) }
        guard let goal = upcoming, let date = goal.targetDate else { return }
        goalID = goal.uuid
        name = "\(goal.title) Plan"
        endDate = date
        suggestPhases()
    }

    private func suggestPhases() {
        phases = PhaseTemplate.suggest(start: startDate, end: endDate, calendar: .current).map {
            PhaseDraft(kind: $0.kind, start: $0.start, end: $0.end)
        }
    }

    private func save() {
        let calendar = Calendar.current
        let target: TrainingPlan
        if let plan {
            target = plan
        } else {
            target = TrainingPlan(name: name, startDate: startDate, endDate: endDate)
            context.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.startDate = calendar.startOfDay(for: startDate)
        target.endDate = calendar.startOfDay(for: endDate)
        target.goal = goals.first { $0.uuid == goalID }

        for phase in target.phases ?? [] {
            context.delete(phase)
        }
        for draft in phases {
            let phase = PlanPhase(kind: draft.kind, startDate: calendar.startOfDay(for: draft.start), endDate: calendar.startOfDay(for: draft.end))
            context.insert(phase)
            phase.plan = target
        }
        onSave(target)
        environment.reconcilePlan()
        dismiss()
    }
}
