import Analysis
import Foundation

/// Zwift's `.zwo` workout file: XML in which every step is power as a fraction of FTP
/// over time. Heart-rate zone targets are written as the matching power zone.
enum ZwiftWorkout {
    static func xml(for export: ExportableWorkout) throws -> String {
        var elements: [String] = []
        let blocks = export.workout.blocks
        for (index, block) in blocks.enumerated() {
            let steps = try block.steps.map { try Timed($0, export.thresholds) }
            // Zwift has one repeating element, for a pair of steady steps.
            if block.repeats > 1, steps.count == 2, let on = steps[0].power, let off = steps[1].power {
                elements.append(
                    "<IntervalsT Repeat=\"\(block.repeats)\" OnDuration=\"\(steps[0].seconds)\" OffDuration=\"\(steps[1].seconds)\""
                        + " OnPower=\"\(fraction(on.middle))\" OffPower=\"\(fraction(off.middle))\"/>")
                continue
            }
            for _ in 0..<block.repeats {
                for step in steps {
                    elements.append(element(step, isFirst: index == 0, isLast: index == blocks.count - 1))
                }
            }
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <workout_file>
                <author>Long Game</author>
                <name>\(escape(export.name))</name>
                <description>\(escape(export.notes))</description>
                <sportType>bike</sportType>
                <tags/>
                <workout>
            \(elements.map { "        \($0)" }.joined(separator: "\n"))
                </workout>
            </workout_file>

            """
    }

    private static func element(_ step: Timed, isFirst: Bool, isLast: Bool) -> String {
        guard let power = step.power else { return "<FreeRide Duration=\"\(step.seconds)\"/>" }
        let range = power.lowerBound != power.upperBound
        // Zwift's warm-up and cool-down are ramps, which suits a range of power.
        switch step.kind {
        case .warmup where isFirst && range:
            return
                "<Warmup Duration=\"\(step.seconds)\" PowerLow=\"\(fraction(power.lowerBound))\" PowerHigh=\"\(fraction(power.upperBound))\"/>"
        case .cooldown where isLast && range:
            return
                "<Cooldown Duration=\"\(step.seconds)\" PowerLow=\"\(fraction(power.upperBound))\" PowerHigh=\"\(fraction(power.lowerBound))\"/>"
        default:
            return "<SteadyState Duration=\"\(step.seconds)\" Power=\"\(fraction(power.middle))\"/>"
        }
    }

    private static func fraction(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.scaledAndRounded(by: 100) / 100)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A step as power-over-time formats see it.
struct Timed {
    var kind: StructuredWorkout.StepKind
    var seconds: Int
    /// Fraction of FTP; nil for a step with no target a power format can express.
    var power: ClosedRange<Double>?

    init(_ step: StructuredWorkout.Step, _ thresholds: TrainingThresholds) throws {
        guard let seconds = step.durationSeconds else { throw WorkoutExportError.needsTimedSteps }
        if step.target?.kind == .power, thresholds.ftpWatts == nil { throw WorkoutExportError.needsFTP }
        self.kind = step.kind
        self.seconds = Int(seconds.rounded())
        self.power = step.target?.ftpFraction(thresholds, approximatingZones: true)
    }
}

extension ClosedRange where Bound == Double {
    var middle: Double { (lowerBound + upperBound) / 2 }
}

extension Double {
    /// Scaled and rounded to a whole number, with binary noise removed first so that a
    /// half such as 0.575 × 100 rounds up as written rather than down.
    func scaledAndRounded(by scale: Double) -> Double {
        ((self * scale * 1000).rounded() / 1000).rounded()
    }
}
