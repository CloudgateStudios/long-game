import Foundation

// App-level value types shared by every module. Stored in SwiftData as raw strings.

public enum Sport: String, Codable, Sendable, CaseIterable, Identifiable {
    case swim, bike, run, strength, other

    public var id: String { rawValue }

    /// Swim, bike and run are plannable in detail and carry sport-specific metrics.
    public var isEndurance: Bool {
        switch self {
        case .swim, .bike, .run: true
        case .strength, .other: false
        }
    }

    public var displayName: String {
        switch self {
        case .swim: "Swim"
        case .bike: "Bike"
        case .run: "Run"
        case .strength: "Strength"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .swim: "figure.pool.swim"
        case .bike: "figure.outdoor.cycle"
        case .run: "figure.run"
        case .strength: "dumbbell"
        case .other: "figure.mixed.cardio"
        }
    }
}

public enum SessionType: String, Codable, Sendable, CaseIterable, Identifiable {
    case easy, long, tempo, intervals, recovery, race, strength, rest, flex, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .easy: "Easy"
        case .long: "Long"
        case .tempo: "Tempo"
        case .intervals: "Intervals"
        case .recovery: "Recovery"
        case .race: "Race"
        case .strength: "Strength"
        case .rest: "Rest"
        case .flex: "Flex"
        case .other: "Other"
        }
    }

    /// Rest and flex mark a whole day rather than a session to complete: rest is fully
    /// off, flex is left for the athlete to decide on the day. Neither has a sport or
    /// targets, is matched to a workout, or counts toward compliance.
    public var isDayMarker: Bool { self == .rest || self == .flex }
}

public enum GoalType: String, Codable, Sendable, CaseIterable {
    case event, fitness, body
}

public enum GoalPriority: String, Codable, Sendable, CaseIterable, Comparable {
    case a = "A"
    case b = "B"
    case c = "C"

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum GoalStatus: String, Codable, Sendable, CaseIterable {
    case active, achieved, abandoned
}

public enum PlanPhaseKind: String, Codable, Sendable, CaseIterable {
    case base, build, peak, taper, recovery

    public var displayName: String { rawValue.capitalized }
}

public enum PlanOrigin: String, Codable, Sendable, CaseIterable {
    case manual, generated
}

public enum PlannedStatus: String, Codable, Sendable, CaseIterable {
    case planned, done, partial, overdone, missed, skipped
}

public enum WorkoutSource: String, Codable, Sendable, CaseIterable {
    case healthKit, fitImport, fixture
}

public enum LoadConfidence: String, Codable, Sendable, CaseIterable {
    /// Load derived from heart-rate or power samples.
    case measured
    /// No samples; load estimated from duration.
    case estimated
}

/// How a workout felt, as the athlete reports it afterwards.
public enum WorkoutFeel: String, Codable, Sendable, CaseIterable, Identifiable {
    case strong, good, ok, tired, poor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .strong: "Strong"
        case .good: "Good"
        case .ok: "OK"
        case .tired: "Tired"
        case .poor: "Poor"
        }
    }
}

public enum ReviewTrigger: String, Codable, Sendable, CaseIterable {
    case weekly, onDemand, planGeneration
}

public enum SuggestionAction: String, Codable, Sendable, CaseIterable {
    case modify, move, remove, add
}

public enum SuggestionStatus: String, Codable, Sendable, CaseIterable {
    case pending, accepted, rejected
}

public enum BiologicalSex: String, Codable, Sendable, CaseIterable {
    case female, male, other
}

public enum ConversationKind: String, Codable, Sendable, CaseIterable {
    /// The coach interviews the athlete and then writes a plan.
    case interview
    /// Open discussion, in which the coach may propose changes to the plan.
    case discussion
}

public enum CoachChargeKind: String, Codable, Sendable, CaseIterable {
    case review, planGeneration, conversation, workoutStructure
}
