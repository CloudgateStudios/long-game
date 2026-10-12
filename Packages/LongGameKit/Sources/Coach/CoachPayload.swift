import Analysis
import Foundation

/// Everything sent to the coach, as compact JSON. Deliberately absent: names, the date
/// of birth, device identifiers, locations and source-app names.
public struct CoachPayload: Codable, Sendable, Equatable {
    public struct Profile: Codable, Sendable, Equatable {
        public var age: Int?
        public var sex: String?
        public var heightCm: Double?
        public var weightKg: Double?
        public var maxHR: Double?
        public var restingHR: Double?
        /// Top of heart-rate zones 1 to 4 in bpm; zone 5 is everything above.
        public var zoneUpperBounds: [Double]?
        public var ftpWatts: Double?
        public var thresholdRunPaceSecPerKm: Double?
        public var thresholdSwimPaceSecPer100m: Double?
        public var sports: [String]
        /// Hours available on Monday through Sunday.
        public var availabilityHoursMonToSun: [Double]
        public var notes: String?
    }

    public struct Goal: Codable, Sendable, Equatable {
        public var title: String
        public var type: String
        public var priority: String
        public var status: String
        public var sport: String?
        public var distanceKm: Double?
        public var date: String?
        public var daysAway: Int?
        public var target: String?
    }

    public struct Phase: Codable, Sendable, Equatable {
        public var kind: String
        public var start: String
        public var end: String
    }

    public struct Session: Codable, Sendable, Equatable {
        public var id: String
        public var date: String
        public var sport: String
        public var type: String
        public var minutes: Double?
        public var km: Double?
        public var intensity: String?
        public var instructions: String?
        /// planned, done, partial, overdone or missed.
        public var status: String
        public var percentOfTarget: Int?
    }

    public struct Plan: Codable, Sendable, Equatable {
        public var start: String
        public var end: String
        public var phases: [Phase]
        public var sessions: [Session]
    }

    public struct Workout: Codable, Sendable, Equatable {
        public var date: String
        public var sport: String
        /// The activity as recorded, for sports the plan does not model (hiking, curling…).
        public var activity: String?
        public var minutes: Double
        public var km: Double?
        public var avgHR: Double?
        public var maxHR: Double?
        public var zoneMinutes: [Double]?
        public var watts: Double?
        public var effort: Double?
        public var load: Double?
        public var loadEstimated: Bool?
        /// The planned session this was matched to; absent when unplanned.
        public var sessionId: String?
    }

    public struct Day: Codable, Sendable, Equatable {
        public var date: String
        public var restingHR: Double?
        public var hrv: Double?
        public var sleepHours: Double?
        public var deepSleepHours: Double?
        public var remSleepHours: Double?
        public var respiratoryRate: Double?
        public var steps: Double?
        public var vo2Max: Double?
        public var weightKg: Double?
        public var load: Double?
        /// Signals outside the athlete's own normal range that day.
        public var flags: [String]?
    }

    public struct Baseline: Codable, Sendable, Equatable {
        public var mean: Double
        public var standardDeviation: Double
    }

    public struct Baselines: Codable, Sendable, Equatable {
        public var hrv: Baseline?
        public var restingHR: Baseline?
        public var sleepHours: Baseline?
    }

    public struct Week: Codable, Sendable, Equatable {
        public var weekStart: String
        public var load: Double
        public var loadBySport: [String: Double]
        public var sessionsPlanned: Int?
        public var sessionsDone: Int?
        public var sessionsPartial: Int?
        public var sessionsMissed: Int?
        public var percentOfPlannedLoad: Int?
    }

    public struct Load: Codable, Sendable, Equatable {
        public var last7DayDailyAverage: Double
        public var last28DayDailyAverage: Double
        public var loadRatio: Double?
        public var loadRatioOutsideSteadyRange: Bool
        public var weeks: [Week]
    }

    public struct PreviousSuggestion: Codable, Sendable, Equatable {
        public var action: String
        public var session: String
        public var rationale: String
        public var status: String
    }

    public struct PreviousReview: Codable, Sendable, Equatable {
        public var date: String
        public var assessment: String
        public var suggestions: [PreviousSuggestion]
    }

    public var today: String
    public var weekday: String
    public var reviewType: String
    public var profile: Profile
    public var goals: [Goal]
    public var plan: Plan?
    public var workouts: [Workout]
    public var daily: [Day]
    public var baselines: Baselines
    public var load: Load
    public var previousReview: PreviousReview?
    /// Present only when a new plan is being asked for.
    public var planRequest: PlanRequest?

    public struct PlanRequest: Codable, Sendable, Equatable {
        public var start: String
        public var end: String
        public var weeks: Int
        /// The goal the plan is built around.
        public var goal: String?
        public var goalDate: String?
    }
}

/// A generated plan, as the model returns it.
public struct PlanResponse: Codable, Sendable, Equatable {
    public struct Phase: Codable, Sendable, Equatable {
        public var kind: PlanPhaseKind
        public var start: String
        public var end: String
    }

    public struct Session: Codable, Sendable, Equatable {
        public var date: String
        public var sport: Sport
        public var sessionType: SessionType
        public var durationMinutes: Double?
        public var distanceKm: Double?
        public var intensity: String?
        public var instructions: String?
    }

    public var summary: String
    public var phases: [Phase]
    public var sessions: [Session]

    public init(summary: String, phases: [Phase], sessions: [Session]) {
        self.summary = summary
        self.phases = phases
        self.sessions = sessions
    }

    /// `summary` comes first so it can be shown while the sessions stream.
    static var schema: [String: Any] {
        func nullable(_ type: String) -> [String: Any] {
            ["anyOf": [["type": type], ["type": "null"]]]
        }
        let phase: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "start", "end"],
            "properties": [
                "kind": ["type": "string", "enum": PlanPhaseKind.allCases.map(\.rawValue)],
                "start": ["type": "string"],
                "end": ["type": "string"],
            ],
        ]
        let session: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["date", "sport", "sessionType", "durationMinutes", "distanceKm", "intensity", "instructions"],
            "properties": [
                "date": ["type": "string"],
                "sport": ["type": "string", "enum": Sport.allCases.map(\.rawValue)],
                "sessionType": ["type": "string", "enum": SessionType.allCases.map(\.rawValue)],
                "durationMinutes": nullable("number"),
                "distanceKm": nullable("number"),
                "intensity": nullable("string"),
                "instructions": nullable("string"),
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["summary", "phases", "sessions"],
            "properties": [
                "summary": ["type": "string"],
                "phases": ["type": "array", "items": phase],
                "sessions": ["type": "array", "items": session],
            ],
        ]
    }
}

/// The structured reply the model is constrained to.
public struct CoachResponse: Codable, Sendable, Equatable {
    public var assessment: String
    public var flags: [String]
    public var suggestions: [CoachSuggestion]
    /// A few words naming the review.
    public var title: String?

    public init(assessment: String, flags: [String], suggestions: [CoachSuggestion], title: String? = nil) {
        self.assessment = assessment
        self.flags = flags
        self.suggestions = suggestions
        self.title = title
    }
}

public struct CoachSuggestion: Codable, Sendable, Equatable {
    public var action: SuggestionAction
    public var sessionId: String?
    public var date: String?
    public var sport: Sport?
    public var sessionType: SessionType?
    public var durationMinutes: Double?
    public var distanceKm: Double?
    public var intensity: String?
    public var instructions: String?
    public var rationale: String

    public init(
        action: SuggestionAction,
        sessionId: String? = nil,
        date: String? = nil,
        sport: Sport? = nil,
        sessionType: SessionType? = nil,
        durationMinutes: Double? = nil,
        distanceKm: Double? = nil,
        intensity: String? = nil,
        instructions: String? = nil,
        rationale: String
    ) {
        self.action = action
        self.sessionId = sessionId
        self.date = date
        self.sport = sport
        self.sessionType = sessionType
        self.durationMinutes = durationMinutes
        self.distanceKm = distanceKm
        self.intensity = intensity
        self.instructions = instructions
        self.rationale = rationale
    }
}

extension CoachResponse {
    /// JSON Schema for the reply. `assessment` comes first so it can be shown while it
    /// streams. Every property is required and nullable ones say so, as strict structured
    /// output expects.
    static var schema: [String: Any] {
        func nullable(_ type: String) -> [String: Any] {
            ["anyOf": [["type": type], ["type": "null"]]]
        }
        func nullableEnum(_ values: [String]) -> [String: Any] {
            ["anyOf": [["type": "string", "enum": values], ["type": "null"]]]
        }
        let suggestion: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "action", "sessionId", "date", "sport", "sessionType", "durationMinutes", "distanceKm", "intensity",
                "instructions", "rationale",
            ],
            "properties": [
                "action": ["type": "string", "enum": SuggestionAction.allCases.map(\.rawValue)],
                "sessionId": nullable("string"),
                "date": nullable("string"),
                "sport": nullableEnum(Sport.allCases.map(\.rawValue)),
                "sessionType": nullableEnum(SessionType.allCases.map(\.rawValue)),
                "durationMinutes": nullable("number"),
                "distanceKm": nullable("number"),
                "intensity": nullable("string"),
                "instructions": nullable("string"),
                "rationale": ["type": "string"],
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["assessment", "flags", "suggestions", "title"],
            "properties": [
                "title": ["type": "string"],
                "assessment": ["type": "string"],
                "flags": ["type": "array", "items": ["type": "string"]],
                "suggestions": ["type": "array", "items": suggestion],
            ],
        ]
    }
}

enum PartialJSON {
    /// The value of a top-level string property in JSON that may still be arriving,
    /// decoded as far as it has got. Used to show the assessment while it streams.
    static func string(forKey key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < text.endIndex, text[index].isWhitespace || text[index] == ":" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)

        var result = ""
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" { break }
            if character == "\\" {
                let next = text.index(after: index)
                // An escape split across two chunks: wait for the rest.
                guard next < text.endIndex else { break }
                switch text[next] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": break
                case "u":
                    guard let end = text.index(next, offsetBy: 5, limitedBy: text.endIndex) else { return result }
                    let hex = text[text.index(after: next)..<end]
                    if let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) {
                        result.unicodeScalars.append(scalar)
                    }
                    index = end
                    continue
                default: result.append(text[next])
                }
                index = text.index(after: next)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }
}
