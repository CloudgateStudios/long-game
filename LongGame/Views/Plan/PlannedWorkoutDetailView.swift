import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

/// One planned session to read: what it asks for, its steps, and how it went against the
/// workout it was matched to. Editing is a step away rather than the first thing shown.
struct PlannedWorkoutDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    let workout: PlannedWorkout
    @State private var isEditing = false

    var body: some View {
        // Deleted from the editor or the menu: there is nothing left to show.
        if workout.isDeleted || workout.modelContext == nil {
            Color.clear.onAppear { dismiss() }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            Section {
                header
            }

            if let matched = workout.matchedWorkout {
                Section {
                    comparison(with: matched)
                    NavigationLink {
                        WorkoutDetailView(workout: matched)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(matched.displayName)
                                Text(
                                    "\(matched.start.formatted(.dateTime.weekday().day().month().hour().minute())) · \(matched.sourceName)"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: matched.sport.symbolName).foregroundStyle(matched.sport.chartColor)
                        }
                    }
                } header: {
                    Text("Planned and done")
                }
            }

            Section("Session") {
                let targets = Format.targets(of: workout)
                if !targets.isEmpty {
                    Text(targets)
                }
                if workout.instructions.isEmpty {
                    if targets.isEmpty {
                        Text("No targets or instructions yet.").foregroundStyle(.secondary)
                    }
                } else {
                    Text(workout.instructions).foregroundStyle(targets.isEmpty ? .primary : .secondary)
                }
            }

            if WorkoutStructurer.canStructure(workout) {
                StructuredWorkoutSection(session: workout)
            }

            if workout.plan?.isDraft != true {
                MatchSection(session: workout)
            }
        }
        .readableWidth()
        .navigationTitle(Format.title(of: workout))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Move to Previous Day", systemImage: "arrow.up") { workout.move(byDays: -1) }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Move to Next Day", systemImage: "arrow.down") { workout.move(byDays: 1) }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Duplicate to Next Week", systemImage: "plus.square.on.square") {
                    workout.duplicate(daysLater: 7)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Delete Session", systemImage: "trash", role: .destructive) {
                    dismiss()
                    context.delete(workout)
                    environment.reconcilePlan()
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            if let plan = workout.plan {
                PlannedWorkoutEditor(plan: plan, workout: workout, date: workout.day)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: workout.symbolName)
                .font(.title)
                .foregroundStyle(workout.tintColor)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.title(of: workout)).font(.title3.bold())
                Text(workout.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            StatusChip(workout: workout)
        }
        .padding(.vertical, 4)
    }

    /// Target against result, in whichever measure the session was planned by.
    private func comparison(with matched: CompletedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                StatTile(title: "Planned", value: plannedValue)
                StatTile(title: "Done", value: doneValue(of: matched))
            }
            if let ratio = workout.complianceRatio {
                ProgressView(value: min(ratio, 1))
                    .tint(workout.status.chipColor)
                    .accessibilityHidden(true)
                Text("\(Format.percent(ratio)) of target").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var plansByDistance: Bool {
        workout.targetDurationSeconds == nil && workout.targetDistanceMeters != nil
    }

    private var plannedValue: String {
        if let seconds = workout.targetDurationSeconds { return Format.duration(seconds) }
        if let meters = workout.targetDistanceMeters { return Format.distance(meters, sport: workout.sport) }
        return "–"
    }

    private func doneValue(of matched: CompletedWorkout) -> String {
        if plansByDistance, let meters = matched.distanceMeters {
            return Format.distance(meters, sport: workout.sport)
        }
        return Format.duration(matched.durationSeconds)
    }
}
