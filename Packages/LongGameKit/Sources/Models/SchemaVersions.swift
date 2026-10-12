import SwiftData

// The store's shape, one version per release that changes it. To change a model: copy the
// current types into a frozen `SchemaV1` namespace, add `SchemaV2` listing the live
// types, and add a stage to the plan. CloudKit only allows changes that add: new
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

public enum LongGameMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
