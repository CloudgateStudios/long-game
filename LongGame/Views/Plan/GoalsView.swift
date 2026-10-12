import Analysis
import Models
import SwiftData
import SwiftUI

struct GoalsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Goal.targetDay) private var goals: [Goal]
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(goals) { goal in
                    NavigationLink {
                        GoalEditor(goal: goal)
                    } label: {
                        GoalRow(goal: goal)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(goals[index]) }
                    environment.saveChanges()
                }
            }
            .overlay {
                if goals.isEmpty {
                    ContentUnavailableView(
                        "No goals", systemImage: "flag.checkered",
                        description: Text("Add the event or target you are training for."))
                }
            }
            .navigationTitle("Goals")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Goal", systemImage: "plus") { isAdding = true }
                }
            }
            .navigationDestination(isPresented: $isAdding) {
                GoalEditor(goal: nil)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}

private struct GoalRow: View {
    let goal: Goal

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                if let date = goal.targetDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if goal.status != .active {
                Text(goal.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Text(goal.priority.rawValue)
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(.tint.opacity(goal.priority == .a ? 0.25 : 0.1), in: .circle)
                .accessibilityLabel("Priority \(goal.priority.rawValue)")
        }
    }
}

/// Creates a goal (when `goal` is nil) or edits one. Pushed inside the Goals sheet.
private struct GoalEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let goal: Goal?
    private let initialDistance: Double?

    @State private var title: String
    @State private var type: GoalType
    @State private var sport: Sport
    @State private var distance: Double?
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var targetMetric: String
    @State private var priority: GoalPriority
    @State private var status: GoalStatus
    @State private var notes: String

    init(goal: Goal?) {
        self.goal = goal
        let sport = goal?.eventSport ?? .run
        _title = State(initialValue: goal?.title ?? "")
        _type = State(initialValue: goal?.type ?? .event)
        _sport = State(initialValue: sport)
        initialDistance = goal?.eventDistanceMeters.map {
            (DistanceEntry.value(meters: $0, sport: sport) * 100).rounded() / 100
        }
        _distance = State(initialValue: initialDistance)
        _hasDate = State(initialValue: goal == nil || goal?.targetDate != nil)
        _date = State(
            initialValue: goal?.targetDate ?? Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now)
        _targetMetric = State(initialValue: goal?.targetMetric ?? "")
        _priority = State(initialValue: goal?.priority ?? .b)
        _status = State(initialValue: goal?.status ?? .active)
        _notes = State(initialValue: goal?.notes ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title)
                Picker("Type", selection: $type) {
                    ForEach(GoalType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Priority", selection: $priority) {
                    ForEach(GoalPriority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Status", selection: $status) {
                    ForEach(GoalStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            } footer: {
                Text("A is the goal your training is built around. B and C goals are fitted in around it.")
            }

            if type == .event {
                Section("Event") {
                    Picker("Sport", selection: $sport) {
                        ForEach(Sport.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("Distance") {
                        HStack {
                            TextField("Optional", value: $distance, format: .number)
                                .multilineTextAlignment(.trailing)
                            Text(DistanceEntry.unit(for: sport).symbol).foregroundStyle(.secondary)
                        }
                    }
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                }
            }

            Section("Target") {
                Toggle("Has a date", isOn: $hasDate)
                if hasDate {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                TextField("Target (for example a finish time)", text: $targetMetric)
            }

            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(goal == nil ? "New Goal" : "Edit Goal")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        let target: Goal
        if let goal {
            target = goal
        } else {
            target = Goal(title: title)
            context.insert(target)
        }
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.type = type
        target.priority = priority
        target.status = status
        target.eventSport = type == .event ? sport : nil
        if type != .event {
            target.eventDistanceMeters = nil
        } else if distance != initialDistance || sport != goal?.eventSport {
            // Untouched distances keep their exact stored value rather than a rounded round trip.
            target.eventDistanceMeters = distance.flatMap {
                $0 > 0 ? DistanceEntry.meters(value: $0, sport: sport) : nil
            }
        }
        target.targetDate = hasDate ? Calendar.current.startOfDay(for: date) : nil
        target.targetMetric = targetMetric.trimmingCharacters(in: .whitespaces)
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        environment.saveChanges()
        dismiss()
    }
}
