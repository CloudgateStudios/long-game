import Analysis
import Foundation

// The seam between health data and the rest of the app. Nothing outside this module
// imports HealthKit; everything else sees these plain records.

public struct HealthWorkoutRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sourceName: String
    public var sport: Sport
    public var activityName: String
    /// Shared by the legs of one multisport workout.
    public var sessionID: UUID?
    public var start: Date
    public var durationSeconds: Double
    public var distanceMeters: Double?
    public var activeEnergyKcal: Double?
    /// Empty when the source wrote only a summary.
    public var heartRate: [HeartRatePoint]
    public var averagePowerWatts: Double?
    public var averageCadence: Double?
    public var effortScore: Double?

    public init(
        id: UUID,
        sourceName: String,
        sport: Sport,
        activityName: String,
        sessionID: UUID? = nil,
        start: Date,
        durationSeconds: Double,
        distanceMeters: Double? = nil,
        activeEnergyKcal: Double? = nil,
        heartRate: [HeartRatePoint] = [],
        averagePowerWatts: Double? = nil,
        averageCadence: Double? = nil,
        effortScore: Double? = nil
    ) {
        self.id = id
        self.sourceName = sourceName
        self.sport = sport
        self.activityName = activityName
        self.sessionID = sessionID
        self.start = start
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.activeEnergyKcal = activeEnergyKcal
        self.heartRate = heartRate
        self.averagePowerWatts = averagePowerWatts
        self.averageCadence = averageCadence
        self.effortScore = effortScore
    }

    public var end: Date { start.addingTimeInterval(durationSeconds) }
}

public struct HealthDailyRecord: Codable, Sendable, Equatable {
    /// Start of the local day.
    public var date: Date
    public var restingHR: Double?
    public var hrvSDNN: Double?
    public var sleepSeconds: Double?
    public var sleepCoreSeconds: Double?
    public var sleepDeepSeconds: Double?
    public var sleepREMSeconds: Double?
    public var sleepAwakeSeconds: Double?
    public var respiratoryRate: Double?
    public var steps: Double?
    public var activeEnergyKcal: Double?
    public var vo2Max: Double?
    public var bodyMassKg: Double?

    public init(date: Date) {
        self.date = date
    }
}

public struct HealthProfileRecord: Codable, Sendable, Equatable {
    public var dateOfBirth: Date?
    public var biologicalSex: BiologicalSex?
    public var heightCm: Double?
    public var weightKg: Double?
    public var ftpWatts: Double?

    public init(
        dateOfBirth: Date? = nil,
        biologicalSex: BiologicalSex? = nil,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        ftpWatts: Double? = nil
    ) {
        self.dateOfBirth = dateOfBirth
        self.biologicalSex = biologicalSex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.ftpWatts = ftpWatts
    }
}

/// Workouts added and removed since an anchor, plus the anchor to pass next time.
public struct WorkoutChanges: Sendable {
    public var upserted: [HealthWorkoutRecord]
    /// Identifiers of deleted workouts. For a multisport workout this is the session ID.
    public var deletedIDs: [UUID]
    /// Opaque; nil when the source has no notion of incremental sync.
    public var anchor: Data?

    public init(upserted: [HealthWorkoutRecord] = [], deletedIDs: [UUID] = [], anchor: Data? = nil) {
        self.upserted = upserted
        self.deletedIDs = deletedIDs
        self.anchor = anchor
    }
}

public protocol HealthDataSource: Sendable {
    /// Which `WorkoutSource` records from this data source are tagged with.
    var workoutSource: WorkoutSource { get }
    /// False on devices with no health store (iPad and Mac act as viewers).
    var isAvailable: Bool { get }

    /// True until the permission sheet has been shown. Health never reveals whether a
    /// read permission was granted, so "not needed" does not mean "granted".
    func needsAuthorization() async -> Bool
    func requestAuthorization() async throws
    func profile() async throws -> HealthProfileRecord
    /// Workouts starting on or after `start` that changed since `anchor` (all of them when
    /// nil). `onProgress` is called with how many of the changed workouts have been read.
    func workoutChanges(
        since anchor: Data?, from start: Date, onProgress: @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> WorkoutChanges
    func dailyMetrics(in interval: DateInterval) async throws -> [HealthDailyRecord]
    /// Calls `onChange` whenever workouts are added or removed, including while the app
    /// is in the background. Must be called on every launch.
    func observeWorkouts(onChange: @escaping @Sendable () async -> Void) async throws
}

extension HealthDataSource {
    public func workoutChanges(since anchor: Data?, from start: Date) async throws -> WorkoutChanges {
        try await workoutChanges(since: anchor, from: start) { _, _ in }
    }
}

/// Where a sync has got to, for showing progress.
public enum SyncStep: Sendable, Equatable {
    case readingProfile
    /// `total` is zero until the number of changed workouts is known.
    case readingWorkouts(done: Int, total: Int)
    case readingDailyMetrics
    case saving
}
