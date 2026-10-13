import SwiftData

// The store's shape, one version per release that changes it. The newest version lists the
// live types; each older one lists a frozen copy (see SchemaV1.swift). To change a model:
// copy the current types into a frozen namespace for the current version, add a new
// version listing the live types, and add a stage to the plan. CloudKit only allows changes that add: new
// optional or defaulted properties and new models. A field that has reached the
// Production schema can never be removed, renamed, retyped or have its encryption changed.

public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            AthleteProfile.self,
            Goal.self,
            TrainingPlan.self,
            PlanPhase.self,
            PlannedWorkout.self,
            CompletedWorkout.self,
            DailyMetrics.self,
            ThresholdSnapshot.self,
            CoachReview.self,
            PlanSuggestion.self,
            CoachConversation.self,
            CoachCharge.self,
        ]
    }
}

/// Adds `PlannedWorkout.activityName`.
public enum SchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            Models.AthleteProfile.self,
            Models.Goal.self,
            Models.TrainingPlan.self,
            Models.PlanPhase.self,
            Models.PlannedWorkout.self,
            Models.CompletedWorkout.self,
            Models.DailyMetrics.self,
            Models.ThresholdSnapshot.self,
            Models.CoachReview.self,
            Models.PlanSuggestion.self,
            Models.CoachConversation.self,
            Models.CoachCharge.self,
        ]
    }
}

public enum LongGameMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}
