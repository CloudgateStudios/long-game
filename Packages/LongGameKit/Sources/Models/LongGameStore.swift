import Analysis
import Foundation
import SwiftData

public enum LongGameStore {
    public enum Mode: Sendable, Equatable {
        /// Tests and previews.
        case inMemory
        /// On-disk store that never syncs. Used for fixture data so synthetic records
        /// cannot reach the real iCloud database.
        case local(name: String)
        /// On-disk store mirrored to the CloudKit private database.
        case cloudKit(containerID: String)
    }

    public static let schema = Schema([
        AthleteProfile.self,
        Goal.self,
        TrainingPlan.self,
        PlanPhase.self,
        PlannedWorkout.self,
        CompletedWorkout.self,
        DailyMetrics.self,
        CoachReview.self,
        PlanSuggestion.self,
        CoachConversation.self,
        CoachCharge.self,
    ])

    public static func makeContainer(mode: Mode) throws -> ModelContainer {
        let configuration: ModelConfiguration
        switch mode {
        case .inMemory:
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        case .local(let name):
            configuration = ModelConfiguration(schema: schema, url: try storeURL(name: name), cloudKitDatabase: .none)
        case .cloudKit(let containerID):
            configuration = ModelConfiguration(
                schema: schema,
                url: try storeURL(name: "LongGame"),
                cloudKitDatabase: .private(containerID)
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Each store gets its own directory so the whole directory (store, WAL, CloudKit
    /// metadata) can carry complete file protection.
    static func storeURL(name: String) throws -> URL {
        let fileManager = FileManager.default
        let directory =
            try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Stores/\(name)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        return directory.appending(path: "\(name).store")
    }
}
