import Analysis
import CoreData
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

    public static let schema = Schema(versionedSchema: SchemaV2.self)

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
        return try makeContainer(configuration: configuration)
    }

    static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(
                for: schema, migrationPlan: LongGameMigrationPlan.self, configurations: [configuration])
        } catch let error as SwiftDataError where error == .unknownDataStoreSchema {
            // A store last written by a build from before version 1 matches no version in
            // the plan. Everything since then only added to it, so it migrates on its own.
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    #if DEBUG
    /// Creates every record type and field in the container's CloudKit Development schema.
    /// CloudKit otherwise adds a field only when a record first carries a value for it, so
    /// rarely-set fields would be missing from the schema deployed to Production, where
    /// nothing can be added on the fly. Run once before each deploy, signed in to iCloud.
    /// It works on a scratch store, so no real record is touched.
    public static func initializeCloudKitSchema(containerID: String) throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV2.models) else {
            throw CocoaError(.persistentStoreIncompatibleSchema)
        }
        let url = try storeURL(name: "SchemaInitialization")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: "LongGame", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        try container.initializeCloudKitSchema()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
    #endif

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
