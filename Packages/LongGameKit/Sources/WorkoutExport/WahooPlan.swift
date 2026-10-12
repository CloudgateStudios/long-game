import Analysis
import Foundation

/// Wahoo's public `plan.json` (version 1.0.0), the file the Wahoo Cloud API takes for a
/// planned workout that then appears on ELEMNT bike computers.
enum WahooPlan {
    static let version = "1.0.0"

    static func data(for export: ExportableWorkout) throws -> Data {
        let thresholds = export.thresholds
        var header: [String: Any] = [
            "name": export.name,
            "version": version,
            "workout_type_family": export.sport == .run ? 1 : 0,
            "workout_type_location": export.isIndoor ? 0 : 1,
        ]
        if !export.notes.isEmpty { header["description"] = String(export.notes.prefix(5000)) }
        if let seconds = export.workout.estimatedDurationSeconds { header["duration_s"] = Int(seconds.rounded()) }
        if let ftp = thresholds.ftpWatts { header["ftp"] = Int(ftp.rounded()) }
        if let maxHR = thresholds.maxHR { header["max_hr"] = Int(maxHR.rounded()) }

        let intervals: [[String: Any]] = try export.workout.blocks.flatMap { block -> [[String: Any]] in
            let steps = try block.steps.map { try interval($0, thresholds) }
            guard block.repeats > 1 else { return steps }
            // The value counts repeats after the first time through.
            return [["exit_trigger_type": "repeat", "exit_trigger_value": block.repeats - 1, "intervals": steps]]
        }
        return try JSONSerialization.data(
            withJSONObject: ["header": header, "intervals": intervals], options: [.prettyPrinted, .sortedKeys])
    }

    private static func interval(_ step: StructuredWorkout.Step, _ thresholds: TrainingThresholds) throws -> [String:
        Any]
    {
        var interval: [String: Any] = ["intensity_type": intensity(step.kind)]
        if let seconds = step.durationSeconds {
            interval["exit_trigger_type"] = "time"
            interval["exit_trigger_value"] = Int(seconds.rounded())
        } else if let meters = step.distanceMeters {
            interval["exit_trigger_type"] = "distance"
            interval["exit_trigger_value"] = Int(meters.rounded())
        } else {
            // The format has no lap-button trigger.
            throw WorkoutExportError.needsTimedSteps
        }
        interval["name"] = step.note ?? step.kind.displayName
        if let target = step.target, let entry = try self.target(target, thresholds) { interval["targets"] = [entry] }
        return interval
    }

    private static func target(_ target: StructuredWorkout.Target, _ thresholds: TrainingThresholds) throws -> [String:
        Any]?
    {
        func entry(_ type: String, _ range: ClosedRange<Double>, digits: Double = 100) -> [String: Any] {
            [
                "type": type, "low": (range.lowerBound * digits).rounded() / digits,
                "high": (range.upperBound * digits).rounded() / digits,
            ]
        }
        switch target.kind {
        case .ftpPercent:
            // A target relative to FTP is only valid with the FTP in the header.
            guard thresholds.ftpWatts != nil else { throw WorkoutExportError.needsFTP }
            return entry("ftp", (target.low / 100)...(target.high / 100))
        case .power:
            return entry("watts", target.low...target.high, digits: 1)
        case .heartRate, .hrZone:
            return target.beatsPerMinute(thresholds).map { entry("hr", $0, digits: 1) }
        case .pace:
            return target.metersPerSecond.map { entry("speed", $0) }
        case .rpe:
            return entry("rpe", target.low...target.high, digits: 1)
        }
    }

    private static func intensity(_ kind: StructuredWorkout.StepKind) -> String {
        switch kind {
        case .warmup: "wu"
        case .work: "active"
        case .recovery: "recover"
        case .cooldown: "cd"
        }
    }
}
