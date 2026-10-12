import Analysis
import HealthIngest
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
    private func note(for workout: CompletedWorkout) -> WorkoutRow.Note? {
        if !workout.isPrimary { return .duplicate }
        if workout.plannedWorkout != nil { return .planned }
        let day = Calendar.current.startOfDay(for: workout.start)
        let isCovered = plans.contains { !$0.isDraft && $0.startDay <= day && day <= $0.endDay }
        return isCovered ? .unplanned : nil
    }

    /// A week's rows: each counted workout with how many other recordings of the same
    /// session sit behind it. A duplicate with nothing counted beside it keeps its own row.
    private func rows(for workouts: [CompletedWorkout]) -> [(workout: CompletedWorkout, others: Int)] {
        let counted = workouts.filter(\.isPrimary)
        var others: [UUID: Int] = [:]
        var orphans: Set<UUID> = []
        for duplicate in workouts where !duplicate.isPrimary {
            if let owner = counted.first(where: {
                DuplicateResolver.isSameSession($0.sessionCandidate, duplicate.sessionCandidate)
            }) {
                others[owner.externalID, default: 0] += 1
            } else {
                orphans.insert(duplicate.externalID)
            }
        }
        return workouts.filter { $0.isPrimary || orphans.contains($0.externalID) }
            .map { ($0, others[$0.externalID] ?? 0) }
    }

    /// Time and load for the workouts that count.
    private func totals(for workouts: [CompletedWorkout]) -> String {
        let counted = workouts.filter(\.isPrimary)
        return [
            Format.duration(counted.reduce(0) { $0 + $1.durationSeconds }),
            "\(Format.load(counted.reduce(0) { $0 + ($1.load ?? 0) })) load",
        ].joined(separator: " · ")
    }

    var body: some View {
        if workouts.isEmpty, environment.healthState == .syncing {
            LoadingPlaceholder(
                title: "Importing your workouts",
                detail: "The first import reads your last 90 days and can take a minute or two.")
        } else if workouts.isEmpty, environment.isImportingFromICloud {
            LoadingPlaceholder(
                title: "Waiting for your workouts",
                detail:
                    "They are read on your iPhone and arrive here through iCloud, which can take a few minutes the first time."
            )
        } else if workouts.isEmpty {
            ContentUnavailableView(
                "No workouts yet",
                systemImage: "figure.run",
                description: Text(
                    environment.healthSource == nil
                        ? "Workouts are read from Apple Health on your iPhone and arrive here through iCloud."
                        : "Completed workouts from Apple Health appear here.")
            )
        } else {
            List {
                if environment.healthSource == nil {
                    Section {
                        Label(
                            "Workouts are read from Apple Health on your iPhone and arrive here through iCloud.",
                            systemImage: "iphone"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                ForEach(weeks, id: \.start) { week in
                    Section {
                        ForEach(rows(for: week.workouts), id: \.workout.externalID) { row in
                            NavigationLink {
                                WorkoutDetailView(workout: row.workout)
                            } label: {
                                WorkoutRow(workout: row.workout, note: note(for: row.workout), others: row.others)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Week of \(week.start.formatted(.dateTime.day().month()))")
                            Spacer()
                            Text(totals(for: week.workouts)).monospacedDigit()
                        }
                    }
                }
            }
            .readableWidth()
        }
    }
}

private struct WorkoutRow: View {
    enum Note {
        case planned, unplanned, duplicate
    }

    let workout: CompletedWorkout
    let note: Note?
    /// Other recordings of the same session folded into this row.
    let others: Int

    private var details: String {
        var parts = [Format.duration(workout.durationSeconds)]
        if let distance = workout.distanceMeters { parts.append(Format.distance(distance)) }
        if let heartRate = workout.averageHR { parts.append(Format.heartRate(heartRate)) }
        if let power = workout.averagePowerWatts {
            parts.append("\(power.formatted(.number.precision(.fractionLength(0)))) W")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Label {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(workout.displayName)
                        Text(workout.start.formatted(.dateTime.weekday().hour().minute()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(details).font(.subheadline).foregroundStyle(.secondary)
                    if others > 0 {
                        Text("+\(others) other recording\(others == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                switch note {
                case .planned: Chip(text: "Planned")
                case .unplanned: Chip(text: "Unplanned", tint: .orange)
                case .duplicate: Chip(text: "Not counted")
                case nil: EmptyView()
                }
            }
        } icon: {
            Image(systemName: workout.sport.symbolName).foregroundStyle(workout.sport.chartColor)
        }
        .opacity(workout.isPrimary ? 1 : 0.55)
    }
}
