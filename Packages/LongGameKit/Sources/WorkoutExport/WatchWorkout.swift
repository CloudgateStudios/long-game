#if canImport(WorkoutKit)
import Analysis
import Foundation
import HealthKit
import WorkoutKit

/// Turns a structured session into a WorkoutKit plan, which the Workout app on Apple
/// Watch runs natively with its own alerts and step-by-step screens.
public enum WatchWorkout {
    /// `id` should be the planned session's own identifier, so scheduling the same session
    /// twice replaces it and a completed workout can be traced back to its plan.
    public static func plan(for export: ExportableWorkout, id: UUID = UUID()) throws -> WorkoutPlan {
        let activity: HKWorkoutActivityType
        switch export.sport {
        case .run: activity = .running
        case .bike: activity = .cycling
        default: throw WorkoutExportError.unsupportedSport
        }
        guard !export.workout.isEmpty else { throw WorkoutExportError.empty }
        let location: HKWorkoutSessionLocationType = export.isIndoor ? .indoor : .outdoor

        func step(_ source: StructuredWorkout.Step) -> WorkoutStep {
            let goal: WorkoutGoal =
                if let seconds = source.durationSeconds {
                    .time(seconds, .seconds)
                } else if let meters = source.distanceMeters {
                    .distance(meters, .meters)
                } else {
                    .open
                }
            var alert = source.target.flatMap { self.alert(for: $0, export.thresholds) }
            // An alert the watch cannot give for this activity would make the whole plan invalid.
            if let candidate = alert, !CustomWorkout.supportsAlert(candidate, activity: activity, location: location) {
                alert = nil
            }
            return WorkoutStep(goal: goal, alert: alert, displayName: source.note)
        }

        // WorkoutKit has one optional warm-up and cool-down outside the interval blocks.
        var blocks = export.workout.blocks
        var warmup: WorkoutStep?
        var cooldown: WorkoutStep?
        if let first = blocks.first, first.repeats == 1, first.steps.count == 1, first.steps[0].kind == .warmup {
            warmup = step(first.steps[0])
            blocks.removeFirst()
        }
        if let last = blocks.last, last.repeats == 1, last.steps.count == 1, last.steps[0].kind == .cooldown {
            cooldown = step(last.steps[0])
            blocks.removeLast()
        }
        let intervals = blocks.map { block in
            IntervalBlock(
                steps: block.steps.map {
                    IntervalStep($0.kind == .recovery || $0.kind == .cooldown ? .recovery : .work, step: step($0))
                },
                iterations: block.repeats)
        }
        let custom = CustomWorkout(
            activity: activity, location: location, displayName: export.name, warmup: warmup, blocks: intervals,
            cooldown: cooldown)
        return WorkoutPlan(.custom(custom), id: id)
    }

    static func alert(for target: StructuredWorkout.Target, _ thresholds: TrainingThresholds) -> (any WorkoutAlert)? {
        switch target.kind {
        case .heartRate, .hrZone:
            // The athlete's zones in this app may differ from the watch's, so send beats
            // per minute when they are known and fall back to the watch's own zone.
            if let bpm = target.beatsPerMinute(thresholds) { return HeartRateRangeAlert.heartRate(bpm) }
            return target.kind == .hrZone ? HeartRateZoneAlert.heartRate(zone: Int(target.low)) : nil
        case .ftpPercent, .power:
            return target.watts(thresholds).map { PowerRangeAlert.power($0, unit: .watts) }
        case .pace:
            return target.metersPerSecond.map { SpeedRangeAlert.speed($0, unit: .metersPerSecond) }
        case .rpe:
            return nil
        }
    }
}
#endif
