import Analysis
import Foundation

/// The `.mrc` and `.erg` text formats: a list of (minute, power) points that trainer
/// software joins up. MRC gives power as a percentage of FTP, ERG in watts.
enum ErgWorkout {
    enum Unit {
        case percent, watts
    }

    static func text(for export: ExportableWorkout, unit: Unit) throws -> String {
        let ftp = export.thresholds.ftpWatts
        if unit == .watts, ftp == nil { throw WorkoutExportError.needsFTP }
        let scale = unit == .watts ? (ftp ?? 0) : 100

        var points: [String] = []
        var elapsed = 0
        for step in export.workout.unrolled {
            let timed = try Timed(step, export.thresholds)
            let value = Int(
                (timed.power?.middle ?? StructuredWorkoutConstants.untargetedFTPFraction).scaledAndRounded(by: scale))
            // Two points at the same power make a flat step; the shared minute between
            // steps makes the change a square edge rather than a ramp.
            points.append("\(minutes(elapsed))\t\(value)")
            elapsed += timed.seconds
            points.append("\(minutes(elapsed))\t\(value)")
        }

        var header = [
            "[COURSE HEADER]", "VERSION = 2", "UNITS = ENGLISH", "DESCRIPTION = \(singleLine(export.notes))",
            "FILE NAME = \(singleLine(export.name))",
        ]
        if unit == .watts, let ftp { header.append("FTP = \(Int(ftp.rounded()))") }
        header += [unit == .watts ? "MINUTES WATTS" : "MINUTES PERCENT", "[END COURSE HEADER]", "[COURSE DATA]"]
        return (header + points + ["[END COURSE DATA]"]).joined(separator: "\n") + "\n"
    }

    private static func minutes(_ seconds: Int) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(seconds) / 60)
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
