import Analysis
import Foundation
import Models
import SwiftData

/// Asks the coach to turn one planned session, as written, into steps a watch or bike
/// computer can run. The steps are stored on the session; the text shown for them and
/// every exported file are then derived from the steps, never written separately.
public struct WorkoutStructurer: Sendable {
    /// What is sent: the session as planned and the athlete's thresholds. Nothing else.
    struct Payload: Codable, Equatable {
        struct Session: Codable, Equatable {
            var sport: String
            var sessionType: String
            var durationMinutes: Double?
            var distanceKm: Double?
            var intensity: String?
            var instructions: String?
        }

        struct Athlete: Codable, Equatable {
            var ftpWatts: Double?
            var zoneUpperBounds: [Double]?
            var maxHR: Double?
            var thresholdRunPaceSecPerKm: Double?
            /// For runs: "pace" or "heartRate", as the athlete prefers to follow them.
            var runTargets: String?
        }

        var session: Session
        var athlete: Athlete
    }

    private let client: ClaudeClient

    public init(client: ClaudeClient = ClaudeClient()) {
        self.client = client
    }

    public static func canStructure(_ session: PlannedWorkout) -> Bool {
        StructuredWorkoutLimits.sports.contains(session.sport) && !session.isDayMarker
    }

    /// Returns the steps without storing them, so the caller can show them first.
    @MainActor
    public func structure(
        _ session: PlannedWorkout,
        model: String,
        apiKey: String?,
        in context: ModelContext,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> StructuredWorkout {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.missingAPIKey
        }
        guard Self.canStructure(session) else { throw CoachError.malformed }
        let user = try Self.payloadJSON(for: session, in: context, now: now, calendar: calendar)

        let message = try await client.send(
            apiKey: apiKey, model: model, system: CoachConfiguration.structurePrompt, user: user,
            format: .workoutStructure,
            effort: CoachConfiguration.structureEffort)
        guard
            let workout = try? JSONDecoder().decode(StructuredWorkout.self, from: Data(message.text.utf8)).normalized(),
            !workout.isEmpty
        else {
            throw CoachError.malformed
        }
        SpendLedger.record(
            message.usage, kind: .workoutStructure, sessionID: session.uuid,
            model: message.model.isEmpty ? model : message.model, requestedModel: model,
            date: now, in: context)
        try context.save()
        return workout
    }

    @MainActor
    static func payloadJSON(
        for session: PlannedWorkout, in context: ModelContext, now: Date = Date(), calendar: Calendar = .current
    ) throws -> String {
        var descriptor = FetchDescriptor<AthleteProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        let profile = try context.fetch(descriptor).first
        let zones = try LoadRecalculator.resolveZones(in: context, now: now, calendar: calendar)
        let payload = Payload(
            session: .init(
                sport: session.sport.rawValue,
                sessionType: session.sessionType.rawValue,
                durationMinutes: session.targetDurationSeconds.map { ($0 / 60).rounded() },
                distanceKm: session.targetDistanceMeters.map { ($0 / 10).rounded() / 100 },
                intensity: session.targetIntensity.isEmpty ? nil : session.targetIntensity,
                instructions: session.instructions.isEmpty ? nil : session.instructions
            ),
            athlete: .init(
                ftpWatts: zones.ftpWatts?.rounded(),
                zoneUpperBounds: zones.bounds,
                maxHR: zones.maxHR?.rounded(),
                thresholdRunPaceSecPerKm: profile?.thresholdRunPaceSecondsPerKm?.rounded(),
                runTargets: session.sport == .run ? (session.runTargets ?? zones.runTargets).rawValue : nil
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    /// JSON Schema for the reply; the same shape `StructuredWorkout` decodes from.
    static var schema: [String: Any] {
        func nullable(_ type: String) -> [String: Any] {
            ["anyOf": [["type": type], ["type": "null"]]]
        }
        let target: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "low", "high"],
            "properties": [
                "kind": ["type": "string", "enum": StructuredWorkout.TargetKind.allCases.map(\.rawValue)],
                "low": ["type": "number"],
                "high": ["type": "number"],
            ],
        ]
        let step: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "durationSeconds", "distanceMeters", "target", "note"],
            "properties": [
                "kind": ["type": "string", "enum": StructuredWorkout.StepKind.allCases.map(\.rawValue)],
                "durationSeconds": nullable("number"),
                "distanceMeters": nullable("number"),
                "target": ["anyOf": [target, ["type": "null"]]],
                "note": nullable("string"),
            ],
        ]
        let block: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["repeats", "steps"],
            "properties": [
                "repeats": ["type": "integer"],
                "steps": ["type": "array", "items": step],
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["blocks"],
            "properties": ["blocks": ["type": "array", "items": block]],
        ]
    }
}
