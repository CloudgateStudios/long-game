import Foundation
import SwiftData

// The models as version 1.0.0 stored them, frozen so a store written by that version is
// still recognised and can be migrated. Stored properties and relationships only. Never
// edit these: a change here makes every existing store unreadable.

extension SchemaV1 {
    @Model final class AthleteProfile {
        @Attribute(.allowsCloudEncryption) var dateOfBirth: Date?
        @Attribute(.allowsCloudEncryption) var biologicalSexRaw: String?
        @Attribute(.allowsCloudEncryption) var heightCm: Double?
        @Attribute(.allowsCloudEncryption) var weightKg: Double?
        @Attribute(.allowsCloudEncryption) var maxHR: Double?
        @Attribute(.allowsCloudEncryption) var restingHRBaseline: Double?
        @Attribute(.allowsCloudEncryption) var zoneUpperBoundsOverride: [Double]?
        @Attribute(.allowsCloudEncryption) var ftpWatts: Double?
        @Attribute(.allowsCloudEncryption) var thresholdRunPaceSecondsPerKm: Double?
        @Attribute(.allowsCloudEncryption) var thresholdSwimPaceSecondsPer100m: Double?
        var runTargetsRaw: String = "heartRate"
        var enabledSportsRaw: [String] = ["swim", "bike", "run", "strength"]
        var availabilityHours: [Double] = [1, 1, 1, 1, 1, 2, 2]
        @Attribute(.allowsCloudEncryption) var coachNotes: String = ""
        var createdAt: Date = Date()

        init() {}
    }

    @Model final class CompletedWorkout {
        var externalID: UUID = UUID()
        var sourceRaw: String = "healthKit"
        @Attribute(.allowsCloudEncryption) var sourceName: String = ""
        var sportRaw: String = "other"
        @Attribute(.allowsCloudEncryption) var activityName: String = ""
        var sessionID: UUID?
        var isPrimary: Bool = true
        var isPrimaryManuallySet: Bool = false
        var isMatchLocked: Bool = false
        @Attribute(.allowsCloudEncryption) var start: Date = Date()
        @Attribute(.allowsCloudEncryption) var durationSeconds: Double = 0
        @Attribute(.allowsCloudEncryption) var distanceMeters: Double?
        @Attribute(.allowsCloudEncryption) var activeEnergyKcal: Double?
        @Attribute(.allowsCloudEncryption) var averageHR: Double?
        @Attribute(.allowsCloudEncryption) var maxHR: Double?
        @Attribute(.allowsCloudEncryption) var heartRateHistogram: [Double]?
        @Attribute(.allowsCloudEncryption) var zoneSeconds: [Double]?
        @Attribute(.allowsCloudEncryption) var averagePowerWatts: Double?
        @Attribute(.allowsCloudEncryption) var averageCadence: Double?
        @Attribute(.allowsCloudEncryption) var effortScore: Double?
        @Attribute(.allowsCloudEncryption) var load: Double?
        var confidenceRaw: String = "measured"
        @Attribute(.allowsCloudEncryption) var perceivedEffort: Int?
        @Attribute(.allowsCloudEncryption) var feelRaw: String?
        @Attribute(.allowsCloudEncryption) var athleteNotes: String = ""

        @Relationship(deleteRule: .nullify, inverse: \PlannedWorkout.matchedWorkout)
        var plannedWorkout: PlannedWorkout?

        init() {}
    }

    @Model final class DailyMetrics {
        var date: Date = Date()
        @Attribute(.allowsCloudEncryption) var restingHR: Double?
        @Attribute(.allowsCloudEncryption) var hrvSDNN: Double?
        @Attribute(.allowsCloudEncryption) var sleepSeconds: Double?
        @Attribute(.allowsCloudEncryption) var sleepCoreSeconds: Double?
        @Attribute(.allowsCloudEncryption) var sleepDeepSeconds: Double?
        @Attribute(.allowsCloudEncryption) var sleepREMSeconds: Double?
        @Attribute(.allowsCloudEncryption) var sleepAwakeSeconds: Double?
        @Attribute(.allowsCloudEncryption) var respiratoryRate: Double?
        @Attribute(.allowsCloudEncryption) var steps: Double?
        @Attribute(.allowsCloudEncryption) var activeEnergyKcal: Double?
        @Attribute(.allowsCloudEncryption) var vo2Max: Double?
        @Attribute(.allowsCloudEncryption) var bodyMassKg: Double?

        init() {}
    }

    @Model final class ThresholdSnapshot {
        var uuid: UUID = UUID()
        var date: Date = Date()
        var createdAt: Date = Date()
        @Attribute(.allowsCloudEncryption) var zoneUpperBounds: [Double]?
        @Attribute(.allowsCloudEncryption) var maxHR: Double?
        @Attribute(.allowsCloudEncryption) var restingHR: Double?
        @Attribute(.allowsCloudEncryption) var ftpWatts: Double?
        @Attribute(.allowsCloudEncryption) var thresholdRunPaceSecondsPerKm: Double?
        @Attribute(.allowsCloudEncryption) var thresholdSwimPaceSecondsPer100m: Double?

        init() {}
    }

    @Model final class Goal {
        var uuid: UUID = UUID()
        @Attribute(.allowsCloudEncryption) var title: String = ""
        var typeRaw: String = "event"
        var eventSportRaw: String?
        var eventDistanceMeters: Double?
        var targetDate: Date?
        @Attribute(.allowsCloudEncryption) var targetMetric: String = ""
        @Attribute(.allowsCloudEncryption) var targetFinishSeconds: Double?
        var priorityRaw: String = "A"
        var statusRaw: String = "active"
        @Attribute(.allowsCloudEncryption) var notes: String = ""
        var createdAt: Date = Date()

        @Relationship(deleteRule: .nullify, inverse: \TrainingPlan.goal)
        var plans: [TrainingPlan]? = []

        init() {}
    }

    @Model final class TrainingPlan {
        var uuid: UUID = UUID()
        var name: String = ""
        var startDate: Date = Date()
        var endDate: Date = Date()
        var originRaw: String = "manual"
        var createdAt: Date = Date()
        var isDraft: Bool = false
        @Attribute(.allowsCloudEncryption) var coachSummary: String = ""

        var goal: Goal?

        @Relationship(deleteRule: .cascade, inverse: \PlanPhase.plan)
        var phases: [PlanPhase]? = []

        @Relationship(deleteRule: .cascade, inverse: \PlannedWorkout.plan)
        var workouts: [PlannedWorkout]? = []

        init() {}
    }

    @Model final class PlanPhase {
        var kindRaw: String = "base"
        var startDate: Date = Date()
        var endDate: Date = Date()

        var plan: TrainingPlan?

        init() {}
    }

    @Model final class PlannedWorkout {
        var uuid: UUID = UUID()
        var date: Date = Date()
        var orderInDay: Int = 0
        var brickID: UUID?
        var sportRaw: String = "run"
        var sessionTypeRaw: String = "easy"
        var targetDurationSeconds: Double?
        var targetDistanceMeters: Double?
        @Attribute(.allowsCloudEncryption) var targetIntensity: String = ""
        @Attribute(.allowsCloudEncryption) var instructions: String = ""
        @Attribute(.allowsCloudEncryption) var structureJSON: String?
        var runTargetsRaw: String?
        var statusRaw: String = "planned"
        var isManualMatch: Bool = false
        var createdAt: Date = Date()

        var plan: TrainingPlan?
        var matchedWorkout: CompletedWorkout?

        @Relationship(deleteRule: .nullify, inverse: \PlanSuggestion.targetWorkout)
        var suggestions: [PlanSuggestion]? = []

        init() {}
    }

    @Model final class CoachReview {
        var uuid: UUID = UUID()
        var date: Date = Date()
        var periodStart: Date = Date()
        var periodEnd: Date = Date()
        var triggerRaw: String = "onDemand"
        @Attribute(.allowsCloudEncryption) var payloadJSON: String = ""
        var model: String = ""
        @Attribute(.allowsCloudEncryption) var assessment: String = ""
        @Attribute(.allowsCloudEncryption) var flags: [String] = []
        @Attribute(.allowsCloudEncryption) var title: String = ""
        var inputTokens: Int?
        var outputTokens: Int?

        @Relationship(deleteRule: .cascade, inverse: \PlanSuggestion.review)
        var suggestions: [PlanSuggestion]? = []

        init() {}
    }

    @Model final class PlanSuggestion {
        var uuid: UUID = UUID()
        var actionRaw: String = "modify"
        @Attribute(.allowsCloudEncryption) var proposedChangeJSON: String = ""
        @Attribute(.allowsCloudEncryption) var rationale: String = ""
        var statusRaw: String = "pending"
        var createdAt: Date = Date()
        @Attribute(.allowsCloudEncryption) var targetSummary: String = ""

        var review: CoachReview?
        var conversation: CoachConversation?
        var sourceID: String = ""
        var targetWorkout: PlannedWorkout?

        init() {}
    }

    @Model final class CoachConversation {
        var uuid: UUID = UUID()
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var kindRaw: String = "discussion"
        @Attribute(.allowsCloudEncryption) var title: String = ""
        var isTitleSettled: Bool = false
        @Attribute(.allowsCloudEncryption) var messagesJSON: String = "[]"
        var model: String = ""
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var estimatedCost: Double = 0
        var reportedDecisionIDs: [String] = []
        var draftPlanID: UUID?
        var draftOutcomeReported: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \PlanSuggestion.conversation)
        var suggestions: [PlanSuggestion]? = []

        init() {}
    }

    @Model final class CoachCharge {
        var uuid: UUID = UUID()
        var date: Date = Date()
        var kindRaw: String = "review"
        var sessionID: UUID = UUID()
        var model: String = ""
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cost: Double = 0

        init() {}
    }
}
