import Analysis
import Foundation
import SwiftData

@Model
public final class AthleteProfile {
    @Attribute(.allowsCloudEncryption) public var dateOfBirth: Date?
    @Attribute(.allowsCloudEncryption) public var biologicalSexRaw: String?
    @Attribute(.allowsCloudEncryption) public var heightCm: Double?
    @Attribute(.allowsCloudEncryption) public var weightKg: Double?
    @Attribute(.allowsCloudEncryption) public var maxHR: Double?
    @Attribute(.allowsCloudEncryption) public var restingHRBaseline: Double?
    /// Upper bounds of zones 1–4 in bpm. When set, wins over the derived zones.
    @Attribute(.allowsCloudEncryption) public var zoneUpperBoundsOverride: [Double]?
    @Attribute(.allowsCloudEncryption) public var ftpWatts: Double?
    @Attribute(.allowsCloudEncryption) public var thresholdRunPaceSecondsPerKm: Double?
    @Attribute(.allowsCloudEncryption) public var thresholdSwimPaceSecondsPer100m: Double?
    public var enabledSportsRaw: [String] = [Sport.swim, .bike, .run, .strength].map(\.rawValue)
    /// Hours available per weekday, Monday first. Zero means unavailable.
    public var availabilityHours: [Double] = [1, 1, 1, 1, 1, 2, 2]
    /// Injuries, constraints and preferences passed to the coach.
    @Attribute(.allowsCloudEncryption) public var coachNotes: String = ""
    public var createdAt: Date = Date()

    public init() {}

    public var biologicalSex: BiologicalSex? {
        get { biologicalSexRaw.flatMap(BiologicalSex.init(rawValue:)) }
        set { biologicalSexRaw = newValue?.rawValue }
    }

    public var enabledSports: [Sport] {
        get { enabledSportsRaw.compactMap(Sport.init(rawValue:)) }
        set { enabledSportsRaw = newValue.map(\.rawValue) }
    }

    /// The coach is sent an age, never the date of birth.
    public func age(on date: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let dateOfBirth else { return nil }
        return calendar.dateComponents([.year], from: dateOfBirth, to: date).year
    }
}

@Model
public final class CompletedWorkout {
    /// HealthKit UUID (or a generated one for FIT imports). De-duplication key; not
    /// declared unique because CloudKit forbids unique constraints.
    public var externalID: UUID = UUID()
    public var sourceRaw: String = WorkoutSource.healthKit.rawValue
    public var sourceName: String = ""
    public var sportRaw: String = Sport.other.rawValue
    /// Original activity name, kept for "other" sports such as hiking or curling.
    public var activityName: String = ""
    /// Shared by the legs of one multisport workout.
    public var sessionID: UUID?
    /// False when another record of the same session counts toward load and matching.
    public var isPrimary: Bool = true
    public var isPrimaryManuallySet: Bool = false
    /// The user matched or un-matched this workout by hand; automatic matching leaves it alone.
    public var isMatchLocked: Bool = false
    @Attribute(.allowsCloudEncryption) public var start: Date = Date()
    @Attribute(.allowsCloudEncryption) public var durationSeconds: Double = 0
    @Attribute(.allowsCloudEncryption) public var distanceMeters: Double?
    @Attribute(.allowsCloudEncryption) public var activeEnergyKcal: Double?
    @Attribute(.allowsCloudEncryption) public var averageHR: Double?
    @Attribute(.allowsCloudEncryption) public var maxHR: Double?
    /// Seconds at each heart rate in fixed bins (see `HeartRateHistogram`). Kept instead
    /// of the raw samples so zones can be recomputed on any device.
    @Attribute(.allowsCloudEncryption) public var heartRateHistogram: [Double]?
    /// Seconds in zones 1–5.
    @Attribute(.allowsCloudEncryption) public var zoneSeconds: [Double]?
    @Attribute(.allowsCloudEncryption) public var averagePowerWatts: Double?
    @Attribute(.allowsCloudEncryption) public var averageCadence: Double?
    @Attribute(.allowsCloudEncryption) public var effortScore: Double?
    @Attribute(.allowsCloudEncryption) public var load: Double?
    public var confidenceRaw: String = LoadConfidence.measured.rawValue

    @Relationship(deleteRule: .nullify, inverse: \PlannedWorkout.matchedWorkout)
    public var plannedWorkout: PlannedWorkout?

    public init(externalID: UUID, source: WorkoutSource, sport: Sport, start: Date, durationSeconds: Double) {
        self.externalID = externalID
        self.sourceRaw = source.rawValue
        self.sportRaw = sport.rawValue
        self.start = start
        self.durationSeconds = durationSeconds
    }

    public var source: WorkoutSource {
        get { WorkoutSource(rawValue: sourceRaw) ?? .healthKit }
        set { sourceRaw = newValue.rawValue }
    }

    public var sport: Sport {
        get { Sport(rawValue: sportRaw) ?? .other }
        set { sportRaw = newValue.rawValue }
    }

    public var confidence: LoadConfidence {
        get { LoadConfidence(rawValue: confidenceRaw) ?? .estimated }
        set { confidenceRaw = newValue.rawValue }
    }

    public var displayName: String {
        sport == .other && !activityName.isEmpty ? activityName : sport.displayName
    }
}

@Model
public final class DailyMetrics {
    /// Start of the local day.
    public var date: Date = Date()
    @Attribute(.allowsCloudEncryption) public var restingHR: Double?
    @Attribute(.allowsCloudEncryption) public var hrvSDNN: Double?
    @Attribute(.allowsCloudEncryption) public var sleepSeconds: Double?
    @Attribute(.allowsCloudEncryption) public var sleepCoreSeconds: Double?
    @Attribute(.allowsCloudEncryption) public var sleepDeepSeconds: Double?
    @Attribute(.allowsCloudEncryption) public var sleepREMSeconds: Double?
    @Attribute(.allowsCloudEncryption) public var sleepAwakeSeconds: Double?
    @Attribute(.allowsCloudEncryption) public var respiratoryRate: Double?
    @Attribute(.allowsCloudEncryption) public var steps: Double?
    @Attribute(.allowsCloudEncryption) public var activeEnergyKcal: Double?
    @Attribute(.allowsCloudEncryption) public var vo2Max: Double?
    @Attribute(.allowsCloudEncryption) public var bodyMassKg: Double?

    public init(date: Date) {
        self.date = date
    }
}
