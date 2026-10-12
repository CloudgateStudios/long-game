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
    public var thresholdRunPaceSecondsPerKm: Double?

    public init(
        ftpWatts: Double? = nil,
        hrZoneUpperBounds: [Double]? = nil,
        maxHR: Double? = nil,
        thresholdRunPaceSecondsPerKm: Double? = nil
    ) {
        self.ftpWatts = ftpWatts.flatMap { $0 > 0 ? $0 : nil }
        self.hrZoneUpperBounds = hrZoneUpperBounds.flatMap { HeartRateZones.isValid($0) ? $0 : nil }
        self.maxHR = maxHR.flatMap { $0 > 0 ? $0 : nil }
        self.thresholdRunPaceSecondsPerKm = thresholdRunPaceSecondsPerKm.flatMap { $0 > 0 ? $0 : nil }
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

    /// Running pace zones as fractions of threshold speed (1 is threshold pace), after the
    /// usual pace-zone tables: zone 2 is 14 to 29 percent slower than threshold, and so on.
    /// Used to turn a heart-rate zone into a pace and back.
    public static let runSpeedZoneFractions: [ClosedRange<Double>] = [
        0.69...0.775, 0.775...0.877, 0.877...0.943, 0.943...1.01, 1.01...1.11,
    ]
    /// Paces converted from zones are rounded to this many seconds, per kilometre or mile.
    public static let paceRounding = 5.0

    // MARK: Profile chart

    /// How hard a step with no target is drawn, by kind, on the scale where 1 is threshold.
    public static let untargetedIntensity: [StructuredWorkout.StepKind: Double] = [
        .warmup: 0.6, .work: 0.75, .recovery: 0.5, .cooldown: 0.5,
    ]
    /// Perceived effort drawn as intensity: this effort counts as threshold, and each point is worth this much.
    public static let thresholdRPE = 7.5
    public static let intensityPerRPEPoint = 0.09
    /// With no threshold pace, the quickest pace in a run with several paces is drawn as
    /// threshold, and a run at one pace as steady.
    public static let assumedSteadyIntensity = 0.7
    /// How wide a step that runs until the lap button is drawn.
    public static let openStepSeconds = 300.0
    /// The speed assumed for a distance step with no pace, to give it a width.
    public static let assumedSpeed: [Sport: Double] = [.run: 3.0, .bike: 7.5]
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

// MARK: - Profile

extension StructuredWorkout {
    /// One step as a bar in the workout's profile: how long, and how hard.
    public struct Segment: Sendable, Equatable {
        public var kind: StepKind
        /// Seconds from the start of the workout.
        public var start: Double
        public var seconds: Double
        /// Effort on a common scale across heart rate, power, pace and RPE: 1 is threshold.
        public var intensity: Double
        /// Zone 1–5 the intensity falls in.
        public var zone: Int
        /// False when the width is a guess: a lap-button step, or a distance with no pace.
        public var isTimed: Bool
        public var step: Step
    }

    /// The workout as a row of bars, every repeat written out, for drawing.
    public func profile(sport: Sport, thresholds: TrainingThresholds = .init()) -> [Segment] {
        let steps = unrolled
        let speeds = steps.compactMap { $0.target?.metersPerSecond }.map { ($0.lowerBound + $0.upperBound) / 2 }
        let fastest = speeds.max()
        let fastestIntensity = Set(speeds).count > 1 ? 1.0 : StructuredWorkoutConstants.assumedSteadyIntensity

        var start = 0.0
        return steps.map { step in
            var seconds = StructuredWorkoutConstants.openStepSeconds
            var isTimed = false
            if let duration = step.durationSeconds {
                (seconds, isTimed) = (duration, true)
            } else if let meters = step.distanceMeters {
                let pace = step.target?.metersPerSecond
                let speed =
                    pace.map { ($0.lowerBound + $0.upperBound) / 2 } ?? StructuredWorkoutConstants.assumedSpeed[sport]
                    ?? 3
                (seconds, isTimed) = (meters / speed, pace != nil)
            }
            let intensity =
                step.target.flatMap {
                    $0.intensity(thresholds, fastestSpeed: fastest, fastestIntensity: fastestIntensity)
                }
                ?? StructuredWorkoutConstants.untargetedIntensity[step.kind] ?? 0.6
            defer { start += seconds }
            return Segment(
                kind: step.kind, start: start, seconds: seconds, intensity: intensity,
                zone: Self.zone(forIntensity: intensity),
                isTimed: isTimed, step: step)
        }
    }

    public static func zone(forIntensity intensity: Double) -> Int {
        let bounds = StructuredWorkoutConstants.powerZoneFractions
        return (bounds.firstIndex { intensity <= $0.upperBound } ?? bounds.count - 1) + 1
    }
}

extension StructuredWorkout.Target {
    /// Effort on the scale where 1 is threshold, or nil when it cannot be placed.
    func intensity(_ thresholds: TrainingThresholds, fastestSpeed: Double?, fastestIntensity: Double) -> Double? {
        let zones = StructuredWorkoutConstants.powerZoneFractions
        func middle(_ range: ClosedRange<Double>) -> Double { (range.lowerBound + range.upperBound) / 2 }
        switch kind {
        case .ftpPercent, .power:
            return ftpFraction(thresholds).map(middle)
        case .hrZone:
            return middle(zones[Int(low) - 1].lowerBound...zones[Int(high) - 1].upperBound)
        case .heartRate:
            // Placed within the athlete's zones, and so on the same scale as a zone target.
            guard let bounds = thresholds.hrZoneUpperBounds else { return nil }
            let bpm = (low + high) / 2
            let zone = bounds.firstIndex { bpm <= $0 } ?? bounds.count
            let floor = zone == 0 ? bounds[0] * StructuredWorkoutConstants.zoneOneFloorFraction : bounds[zone - 1]
            let ceiling = zone == bounds.count ? max(thresholds.maxHR ?? 0, bounds[zone - 1] + 1) : bounds[zone]
            let position = min(max((bpm - floor) / (ceiling - floor), 0), 1)
            return zones[zone].lowerBound + position * (zones[zone].upperBound - zones[zone].lowerBound)
        case .pace:
            guard let speed = metersPerSecond.map(middle) else { return nil }
            if let threshold = thresholds.thresholdRunPaceSecondsPerKm {
                // Placed within the running pace zones, so easy running reads as easy
                // rather than by its raw fraction of threshold speed.
                let paceZones = StructuredWorkoutConstants.runSpeedZoneFractions
                let fraction = speed / (1000 / threshold)
                let zone = paceZones.firstIndex { fraction <= $0.upperBound } ?? paceZones.count - 1
                let span = paceZones[zone].upperBound - paceZones[zone].lowerBound
                let position = min(max((fraction - paceZones[zone].lowerBound) / span, 0), 1)
                return zones[zone].lowerBound + position * (zones[zone].upperBound - zones[zone].lowerBound)
            }
            return fastestSpeed.map { speed / $0 * fastestIntensity }
        case .rpe:
            let points = (low + high) / 2 - StructuredWorkoutConstants.thresholdRPE
            return max(1 + points * StructuredWorkoutConstants.intensityPerRPEPoint, 0.3)
        }
    }
}

// MARK: - Pace or heart rate

/// What a run's targets are given in. The steps are stored as written; this chooses how
/// they are shown and sent to a device.
public enum RunTargetMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case heartRate, pace

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .heartRate: "Heart Rate"
        case .pace: "Pace"
        }
    }
}

extension StructuredWorkout {
    /// What most of the targets are in already; nil when none is a heart rate or a pace.
    public var runTargetMode: RunTargetMode? {
        let kinds = unrolled.compactMap(\.target?.kind)
        let pace = kinds.count { $0 == .pace }
        let heartRate = kinds.count { $0 == .hrZone || $0 == .heartRate }
        if pace == 0 && heartRate == 0 { return nil }
        return pace > heartRate ? .pace : .heartRate
    }

    /// Whether any target would need converting to be in `mode`.
    public func needsConversion(to mode: RunTargetMode) -> Bool {
        unrolled.contains { step in
            switch step.target?.kind {
            case .pace: mode == .heartRate
            case .hrZone, .heartRate: mode == .pace
            default: false
            }
        }
    }

    /// The same workout with heart-rate targets as paces, or paces as heart-rate zones.
    /// Both directions go through the athlete's threshold pace; without it, or for a
    /// target that cannot be placed, the target is left as it was. Power and effort
    /// targets are never touched.
    /// Converted paces are rounded in `paceUnit`, so they read as round numbers to the athlete.
    public func expressed(
        as mode: RunTargetMode, thresholds: TrainingThresholds, paceUnit: PaceUnit = .perKilometer
    ) -> StructuredWorkout {
        var copy = self
        for block in copy.blocks.indices {
            for step in copy.blocks[block].steps.indices {
                if let target = copy.blocks[block].steps[step].target {
                    copy.blocks[block].steps[step].target = target.expressed(
                        as: mode, thresholds: thresholds, paceUnit: paceUnit)
                }
            }
        }
        return copy
    }
}

extension StructuredWorkout.Target {
    func expressed(
        as mode: RunTargetMode, thresholds: TrainingThresholds, paceUnit: StructuredWorkout.PaceUnit
    ) -> StructuredWorkout.Target {
        guard let threshold = thresholds.thresholdRunPaceSecondsPerKm else { return self }
        let paceZones = StructuredWorkoutConstants.runSpeedZoneFractions
        switch (mode, kind) {
        case (.pace, .hrZone), (.pace, .heartRate):
            guard let zones = heartRateZones(thresholds) else { return self }
            let step = StructuredWorkoutConstants.paceRounding
            // Rounded in the athlete's unit, then stored per kilometre as every pace is.
            let scale = paceUnit.meters / 1000
            func pace(_ fraction: Double) -> Double { (threshold / fraction * scale / step).rounded() * step / scale }
            // The faster end of the hardest zone to the slower end of the easiest.
            return .init(
                .pace, pace(paceZones[zones.upperBound - 1].upperBound),
                pace(paceZones[zones.lowerBound - 1].lowerBound))
        case (.heartRate, .pace):
            let fraction = threshold / ((low + high) / 2)
            let zone = (paceZones.firstIndex { fraction <= $0.upperBound } ?? paceZones.count - 1) + 1
            return .init(.hrZone, Double(zone))
        default:
            return self
        }
    }

    /// The heart-rate zones a heart-rate target spans.
    private func heartRateZones(_ thresholds: TrainingThresholds) -> ClosedRange<Int>? {
        switch kind {
        case .hrZone:
            return Int(low)...Int(high)
        case .heartRate:
            guard let bounds = thresholds.hrZoneUpperBounds else { return nil }
            func zone(_ bpm: Double) -> Int { (bounds.firstIndex { bpm <= $0 } ?? bounds.count) + 1 }
            // A range that only just touches the next zone up still belongs to the lower one.
            return zone(low + 1)...max(zone(low + 1), zone(high))
        default:
            return nil
        }
    }
}
