import Analysis
import HealthIngest
import Models
import SwiftUI

/// Completed workouts by day. Other recordings of a session are folded into the one that
/// counts; a duplicate with nothing counted beside it keeps its own entry.
struct WorkoutLog {
    struct Entry: Identifiable {
        let workout: CompletedWorkout
        /// Other recordings of the same session folded into this entry.
        let others: Int

        var id: UUID { workout.externalID }
    }

    private var byDay: [Date: [Entry]] = [:]
    private var others: [UUID: Int] = [:]
    private let calendar: Calendar

    var isEmpty: Bool { byDay.isEmpty }

    init(_ workouts: [CompletedWorkout] = [], calendar: Calendar = .current) {
        self.calendar = calendar
        let grouped = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.start) }
        for (day, workouts) in grouped {
            let counted = workouts.filter(\.isPrimary)
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
            byDay[day] = workouts.filter { $0.isPrimary || orphans.contains($0.externalID) }
                .sorted { $0.start < $1.start }
                .map { Entry(workout: $0, others: others[$0.externalID] ?? 0) }
        }
    }

    func entries(on day: Date) -> [Entry] {
        byDay[calendar.startOfDay(for: day)] ?? []
    }

    /// How many other recordings of `workout` sit behind it.
    func others(for workout: CompletedWorkout) -> Int {
        others[workout.externalID] ?? 0
    }

    /// What was done on `day` beyond the sessions `plan` shows: with no plan, everything.
    func extras(on day: Date, beyond plan: TrainingPlan?) -> [Entry] {
        entries(on: day).filter { entry in
            guard let plan, let planned = entry.workout.plannedWorkout else { return true }
            return planned.plan !== plan
        }
    }

    /// Time and load for the workouts that count.
    func totals(on days: [Date]) -> (count: Int, seconds: Double, load: Double) {
        let counted = days.flatMap { entries(on: $0) }.map(\.workout).filter(\.isPrimary)
        return (
            counted.count,
            counted.reduce(0) { $0 + $1.durationSeconds },
            counted.reduce(0) { $0 + ($1.load ?? 0) }
        )
    }
}

extension TrainingPlan {
    /// Whether `day` falls inside the plan's dates.
    func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: day)
        return calendar.startOfDay(for: startDay) <= day && day <= calendar.startOfDay(for: endDay)
    }
}

extension Format {
    /// "47m · 8.1 km · 142 bpm · 180 W", with whatever the workout recorded.
    static func summary(of workout: CompletedWorkout) -> String {
        var parts = [duration(workout.durationSeconds)]
        if let meters = workout.distanceMeters { parts.append(distance(meters)) }
        if let bpm = workout.averageHR { parts.append(heartRate(bpm)) }
        if let power = workout.averagePowerWatts {
            parts.append("\(power.formatted(.number.precision(.fractionLength(0)))) W")
        }
        return parts.joined(separator: " · ")
    }
}

/// A day's planned sessions, then whatever else was done on it.
struct DayRows: View {
    let plan: TrainingPlan?
    let day: Date
    let log: WorkoutLog
    @Binding var sheet: PlanSheet?

    var body: some View {
        ForEach(plan?.workouts(on: day) ?? []) { workout in
            PlannedWorkoutRow(
                workout: workout, others: workout.matchedWorkout.map(log.others(for:)) ?? 0, sheet: $sheet)
        }
        ForEach(log.extras(on: day, beyond: plan)) { entry in
            CompletedWorkoutRow(entry: entry, note: note(for: entry.workout))
        }
    }

    /// How the workout relates to the plan, when that is worth saying.
    private func note(for workout: CompletedWorkout) -> CompletedWorkoutRow.Note? {
        if !workout.isPrimary { return .duplicate }
        if workout.plannedWorkout != nil { return nil }
        return plan?.covers(day) == true ? .extra : nil
    }
}

/// One completed workout that no session on screen asked for; tap to open it.
struct CompletedWorkoutRow: View {
    enum Note {
        case extra, duplicate
    }

    let entry: WorkoutLog.Entry
    let note: Note?

    private var workout: CompletedWorkout { entry.workout }

    var body: some View {
        NavigationLink {
            WorkoutDetailView(workout: workout)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: workout.sport.symbolName)
                    .foregroundStyle(workout.sport.chartColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(workout.displayName).foregroundStyle(.primary)
                        Text(workout.start.formatted(.dateTime.hour().minute()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(Format.summary(of: workout)).font(.subheadline).foregroundStyle(.secondary)
                    OtherRecordings(count: entry.others)
                }
                Spacer(minLength: 0)
                switch note {
                case .extra: Chip(text: "Extra", tint: .orange)
                case .duplicate: Chip(text: "Not counted")
                case nil: EmptyView()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(workout.isPrimary ? 1 : 0.55)
    }
}

/// "+1 other recording", under a workout that has duplicates folded into it.
struct OtherRecordings: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("+\(count) other recording\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
