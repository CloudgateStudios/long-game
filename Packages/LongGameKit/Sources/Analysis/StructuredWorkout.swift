import Foundation

/// A run or ride broken into steps that a watch, bike computer or trainer can lead the
/// athlete through. This is the single source for a structured session: the text shown in
/// the app and every exported file are derived from it, so they cannot disagree.
public struct StructuredWorkout: Codable, Sendable, Equatable {
    public enum StepKind: String, Codable, Sendable, CaseIterable {
        case warmup, work, recovery, cooldown
    }

    public enum TargetKind: String, Codable, Sendable, CaseIterable {
        /// Heart-rate zone 1–5. `low` and `high` are zone numbers, usually the same.
        case hrZone
        /// Heart rate in beats per minute.
        case heartRate
        /// Power as a percentage of FTP: 100 is threshold.
        case ftpPercent
        /// Power in watts.
        case power
        /// Pace in seconds per kilometre. `low` is the faster end.
        case pace
        /// Perceived effort 1–10. No device enforces it; it is shown as text only.
        case rpe
    }

    public struct Target: Codable, Sendable, Equatable {
        public var kind: TargetKind
        public var low: Double
        public var high: Double

        public init(_ kind: TargetKind, _ low: Double, _ high: Double? = nil) {
            self.kind = kind
            self.low = min(low, high ?? low)
            self.high = max(low, high ?? low)
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        public var kind: StepKind
        /// A step ends after a time, a distance, or (with neither) when the athlete presses lap.
        public var durationSeconds: Double?
        public var distanceMeters: Double?
        public var target: Target?
        /// A short cue shown beside the step, for example "high cadence".
        public var note: String?

        public init(
            _ kind: StepKind, seconds: Double? = nil, meters: Double? = nil, target: Target? = nil, note: String? = nil
        ) {
            self.kind = kind
            self.durationSeconds = seconds
            self.distanceMeters = meters
            self.target = target
            self.note = note
        }
    }

    /// One or more steps done `repeats` times in a row. A plain step is a block of one.
    public struct Block: Codable, Sendable, Equatable {
        public var repeats: Int
        public var steps: [Step]

        public init(repeats: Int = 1, steps: [Step]) {
            self.repeats = repeats
            self.steps = steps
        }
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// Every step in the order it is done, with repeats written out.
    public var unrolled: [Step] {
        blocks.flatMap { block in (0..<max(block.repeats, 1)).flatMap { _ in block.steps } }
    }

    public var isEmpty: Bool { blocks.allSatisfy(\.steps.isEmpty) }

    /// What a model or a hand edit produced, made safe to export: values out of range are
    /// dropped rather than trusted, and empty blocks removed.
    public func normalized() -> StructuredWorkout {
        StructuredWorkout(
            blocks: blocks.compactMap { block in
                let steps = block.steps.map { step -> Step in
                    var step = step
                    if let seconds = step.durationSeconds,
                        !(seconds > 0 && seconds <= StructuredWorkoutLimits.maxStepSeconds)
                    {
                        step.durationSeconds = nil
                    }
                    if let meters = step.distanceMeters,
                        !(meters > 0 && meters <= StructuredWorkoutLimits.maxStepMeters)
                    {
                        step.distanceMeters = nil
                    }
                    // A step ends one way. Time wins when both were given.
                    if step.durationSeconds != nil { step.distanceMeters = nil }
                    if let target = step.target {
                        step.target = target.isPlausible ? Target(target.kind, target.low, target.high) : nil
                    }
                    if let note = step.note?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        step.note = note.isEmpty ? nil : note
                    }
                    return step
                }
                guard !steps.isEmpty else { return nil }
                return Block(repeats: min(max(block.repeats, 1), StructuredWorkoutLimits.maxRepeats), steps: steps)
            })
    }
}

public enum StructuredWorkoutLimits {
    public static let maxRepeats = 99
    public static let maxStepSeconds = 12.0 * 3600
    public static let maxStepMeters = 300_000.0
    /// Sports a structured workout can be built for.
    public static let sports: Set<Sport> = [.run, .bike]
}

extension StructuredWorkout.Target {
    var isPlausible: Bool {
        let range: ClosedRange<Double> =
            switch kind {
            case .hrZone: 1...5
            case .heartRate: 60...230
            case .ftpPercent: 20...300
            case .power: 30...2000
            case .pace: 120...1200
            case .rpe: 1...10
            }
        return range.contains(low) && range.contains(high)
    }
}

/// The athlete's own numbers, needed to turn a relative target ("Z2", "90% FTP") into
/// something a device understands (bpm, watts).
public struct TrainingThresholds: Sendable, Equatable {
    public var ftpWatts: Double?
    /// Upper bounds of heart-rate zones 1–4 in bpm.
    public var hrZoneUpperBounds: [Double]?
    public var maxHR: Double?

    public init(ftpWatts: Double? = nil, hrZoneUpperBounds: [Double]? = nil, maxHR: Double? = nil) {
        self.ftpWatts = ftpWatts.flatMap { $0 > 0 ? $0 : nil }
        self.hrZoneUpperBounds = hrZoneUpperBounds.flatMap { HeartRateZones.isValid($0) ? $0 : nil }
        self.maxHR = maxHR.flatMap { $0 > 0 ? $0 : nil }
    }
}

extension StructuredWorkout.Target {
    /// Power as a fraction of FTP. Heart-rate zones have no exact power equivalent, so
    /// `approximatingZones` maps them onto the matching power zone for power-only formats.
    public func ftpFraction(_ thresholds: TrainingThresholds, approximatingZones: Bool = false) -> ClosedRange<Double>?
    {
        switch kind {
        case .ftpPercent:
            return (low / 100)...(high / 100)
        case .power:
            guard let ftp = thresholds.ftpWatts else { return nil }
            return (low / ftp)...(high / ftp)
        case .hrZone where approximatingZones:
            let bounds = StructuredWorkoutConstants.powerZoneFractions
            return bounds[Int(low) - 1].lowerBound...bounds[Int(high) - 1].upperBound
        default:
            return nil
        }
    }

    public func watts(_ thresholds: TrainingThresholds) -> ClosedRange<Double>? {
        switch kind {
        case .power:
            return low...high
        case .ftpPercent:
            guard let ftp = thresholds.ftpWatts else { return nil }
            return (low / 100 * ftp).rounded()...(high / 100 * ftp).rounded()
        default:
            return nil
        }
    }

    public func beatsPerMinute(_ thresholds: TrainingThresholds) -> ClosedRange<Double>? {
        switch kind {
        case .heartRate:
            return low...high
        case .hrZone:
            guard let bounds = thresholds.hrZoneUpperBounds else { return nil }
            let lowZone = Int(low)
            let highZone = Int(high)
            // Zone 1 has no floor of its own; zone 5 runs up to max.
            let floor =
                lowZone == 1
                ? (bounds[0] * StructuredWorkoutConstants.zoneOneFloorFraction).rounded() : bounds[lowZone - 2]
            let ceiling = highZone == 5 ? max(thresholds.maxHR ?? 0, bounds[3] + 1) : bounds[highZone - 1]
            return floor...ceiling
        default:
            return nil
        }
    }

    /// Speed in metres per second, slower end first.
    public var metersPerSecond: ClosedRange<Double>? {
        kind == .pace ? (1000 / high)...(1000 / low) : nil
    }
}

public enum StructuredWorkoutConstants {
    /// Power zones as fractions of FTP, used only to stand in for a heart-rate zone in
    /// formats that carry nothing but power (ZWO, MRC, ERG).
    public static let powerZoneFractions: [ClosedRange<Double>] = [
        0.45...0.55, 0.56...0.75, 0.76...0.90, 0.91...1.05, 1.06...1.20,
    ]
    /// Where zone 1 is taken to start, as a fraction of its upper bound.
    public static let zoneOneFloorFraction = 0.85
    /// What power-only formats use for a step with no target.
    public static let untargetedFTPFraction = 0.5
}

// MARK: - Totals

extension StructuredWorkout {
    /// Total time, estimating distance steps from their pace target. Nil when any step's
    /// length cannot be known ahead of time.
    public var estimatedDurationSeconds: Double? {
        var total = 0.0
        for step in unrolled {
            if let seconds = step.durationSeconds {
                total += seconds
            } else if let meters = step.distanceMeters, let speed = step.target?.metersPerSecond {
                total += meters / ((speed.lowerBound + speed.upperBound) / 2)
            } else {
                return nil
            }
        }
        return total
    }
}

// MARK: - Text

extension StructuredWorkout {
    public enum PaceUnit: Sendable {
        case perKilometer, perMile

        var meters: Double { self == .perKilometer ? 1000 : 1609.344 }
        var suffix: String { self == .perKilometer ? "/km" : "/mi" }
    }

    public struct TextStyle: Sendable {
        public var paceUnit: PaceUnit
        public init(paceUnit: PaceUnit = .perKilometer) {
            self.paceUnit = paceUnit
        }
    }

    /// One line per block, for example:
    ///
    ///     Warm up 10 min at Z2
    ///     5 × (4 min at 105–110% FTP, 3 min recovery at Z1)
    ///     Cool down 10 min at Z1
    public func lines(_ style: TextStyle = TextStyle()) -> [String] {
        blocks.map { block in
            let steps = block.steps.enumerated().map { index, step in
                // Inside a repeat the step kind is clear from its place, apart from the recovery.
                step.text(
                    style, named: block.repeats == 1 || step.kind == .recovery,
                    capitalized: block.repeats == 1 && index == 0)
            }
            return block.repeats > 1
                ? "\(block.repeats) × (\(steps.joined(separator: ", ")))" : steps.joined(separator: ", ")
        }
    }

    public func text(_ style: TextStyle = TextStyle()) -> String {
        lines(style).joined(separator: "\n")
    }
}

extension StructuredWorkout.StepKind {
    public var displayName: String {
        switch self {
        case .warmup: "Warm up"
        case .work: "Work"
        case .recovery: "Recovery"
        case .cooldown: "Cool down"
        }
    }
}

extension StructuredWorkout.Step {
    public var lengthText: String {
        if let seconds = durationSeconds { return StructuredWorkout.clock(seconds) }
        if let meters = distanceMeters {
            return meters < 1000
                ? "\(StructuredWorkout.number(meters)) m" : "\(StructuredWorkout.number(meters / 1000)) km"
        }
        return "until lap"
    }

    func text(_ style: StructuredWorkout.TextStyle, named: Bool, capitalized: Bool) -> String {
        var parts: [String] = []
        if named && kind != .work { parts.append(capitalized ? kind.displayName : kind.displayName.lowercased()) }
        parts.append(lengthText)
        if let target { parts.append("at \(target.text(style))") }
        var text = parts.joined(separator: " ")
        if let note { text += " (\(note))" }
        return text
    }
}

extension StructuredWorkout.Target {
    public func text(_ style: StructuredWorkout.TextStyle = .init()) -> String {
        func range(_ format: (Double) -> String, prefix: String = "", suffix: String = "") -> String {
            low == high ? "\(prefix)\(format(low))\(suffix)" : "\(prefix)\(format(low))–\(format(high))\(suffix)"
        }
        switch kind {
        case .hrZone: return range(StructuredWorkout.number, prefix: "Z")
        case .heartRate: return range(StructuredWorkout.number, suffix: " bpm")
        case .ftpPercent: return range(StructuredWorkout.number, suffix: "% FTP")
        case .power: return range(StructuredWorkout.number, suffix: " W")
        case .rpe: return range(StructuredWorkout.number, prefix: "RPE ")
        case .pace:
            let scale = style.paceUnit.meters / 1000
            return range({ StructuredWorkout.minutesAndSeconds($0 * scale) }, suffix: style.paceUnit.suffix)
        }
    }
}

extension StructuredWorkout {
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func minutesAndSeconds(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "45 s", "4 min", "1:30 min", "1 h 15 min".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total % 60 != 0 { return "\(minutesAndSeconds(seconds)) min" }
        let minutes = total / 60
        if minutes < 90 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
