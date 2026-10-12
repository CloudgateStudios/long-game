import Analysis
import Models
import SwiftData
import SwiftUI

struct LogView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \CompletedWorkout.start, order: .reverse) private var workouts: [CompletedWorkout]
    @Query private var plans: [TrainingPlan]

    private var weeks: [(start: Date, workouts: [CompletedWorkout])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: workouts) { workout in
            calendar.dateInterval(of: .weekOfYear, for: workout.start)?.start ?? workout.start
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    /// How the workout relates to the plan, when that is worth saying.
    private func note(for workout: CompletedWorkout) -> String? {
        if !workout.isPrimary { return "Duplicate, not counted" }
        if let planned = workout.plannedWorkout { return "Planned: \(Format.title(of: planned))" }
        let day = Calendar.current.startOfDay(for: workout.start)
        let isCovered = plans.contains { !$0.isDraft && $0.startDate <= day && day <= $0.endDate }
        return isCovered ? "Unplanned" : nil
    }

    var body: some View {
        if workouts.isEmpty, environment.healthState == .syncing {
            LoadingPlaceholder(title: "Importing your workouts", detail: "The first import reads your last 90 days and can take a minute or two.")
        } else if workouts.isEmpty, environment.isImportingFromICloud {
            LoadingPlaceholder(title: "Waiting for your workouts", detail: "They are read on your iPhone and arrive here through iCloud, which can take a few minutes the first time.")
        } else if workouts.isEmpty {
            ContentUnavailableView(
                "No workouts yet",
                systemImage: "figure.run",
                description: Text(environment.healthSource == nil
                    ? "Workouts are read from Apple Health on your iPhone and arrive here through iCloud."
                    : "Completed workouts from Apple Health appear here.")
            )
        } else {
            List {
                if environment.healthSource == nil {
                    Section {
                        Label("Workouts are read from Apple Health on your iPhone and arrive here through iCloud.", systemImage: "iphone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(weeks, id: \.start) { week in
                    Section("Week of \(week.start.formatted(.dateTime.day().month()))") {
                        ForEach(week.workouts) { workout in
                            NavigationLink {
                                WorkoutDetailView(workout: workout)
                            } label: {
                                WorkoutRow(workout: workout, note: note(for: workout))
                            }
                        }
                    }
                }
            }
            .readableWidth()
        }
    }
}

private struct WorkoutRow: View {
    let workout: CompletedWorkout
    let note: String?

    private var details: String {
        var parts = [Format.duration(workout.durationSeconds)]
        if let distance = workout.distanceMeters { parts.append(Format.distance(distance)) }
        if let heartRate = workout.averageHR { parts.append(Format.heartRate(heartRate)) }
        if let power = workout.averagePowerWatts { parts.append("\(power.formatted(.number.precision(.fractionLength(0)))) W") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(workout.displayName)
                    Spacer()
                    Text(workout.start.formatted(.dateTime.weekday().hour().minute()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(details).font(.subheadline).foregroundStyle(.secondary)
                Text([workout.sourceName, note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: workout.sport.symbolName)
        }
        .opacity(workout.isPrimary ? 1 : 0.55)
    }
}
