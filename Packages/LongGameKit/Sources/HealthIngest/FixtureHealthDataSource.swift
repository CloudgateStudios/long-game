import Analysis
import Foundation

/// Loads synthetic workouts and daily metrics from bundled JSON. Used by the simulator,
/// previews and tests, none of which have real health data.
///
/// Fixture dates are stored as day offsets from "today" so the data always looks recent.
public struct FixtureHealthDataSource: HealthDataSource {
    public let workoutSource: WorkoutSource = .fixture
    public let isAvailable = true

    private let fixture: Fixture
    private let now: Date
    private let calendar: Calendar
    private let workoutDelay: Duration

    /// `workoutDelay` slows the import down per workout, to rehearse what a long first
    /// sync from Apple Health looks like.
    public init(now: Date = Date(), calendar: Calendar = .current, workoutDelay: Duration = .zero) throws {
        self.workoutDelay = workoutDelay
        guard let url = Bundle.module.url(forResource: "health-fixture", withExtension: "json") else {
            throw FixtureError.missingResource
        }
        self.fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        self.now = now
        self.calendar = calendar
    }

    public func needsAuthorization() async -> Bool { false }

    public func requestAuthorization() async throws {}

    public func observeWorkouts(onChange: @escaping @Sendable () async -> Void) async throws {}

    public func profile() async throws -> HealthProfileRecord {
        HealthProfileRecord(
            dateOfBirth: calendar.date(byAdding: .year, value: -fixture.profile.ageYears, to: startOfToday),
            biologicalSex: BiologicalSex(rawValue: fixture.profile.biologicalSex),
            heightCm: fixture.profile.heightCm,
            weightKg: fixture.days.last?.bodyMassKg
        )
    }

    /// The fixture never changes, so everything arrives on the first call.
    public func workoutChanges(since anchor: Data?, from start: Date, onProgress: @Sendable (Int, Int) -> Void) async throws -> WorkoutChanges {
        guard anchor == nil else { return WorkoutChanges(anchor: anchor) }
        let records = try await workouts(in: DateInterval(start: start, end: max(start, now)))
        if workoutDelay > .zero {
            for index in records.indices {
                onProgress(index, records.count)
                try await Task.sleep(for: workoutDelay)
            }
        }
        onProgress(records.count, records.count)
        return WorkoutChanges(upserted: records, anchor: Data("fixture".utf8))
    }

    public func workouts(in interval: DateInterval) async throws -> [HealthWorkoutRecord] {
        fixture.workouts.compactMap { item in
            guard let start = date(dayOffset: item.dayOffset, minuteOfDay: item.startMinute),
                  interval.contains(start) else { return nil }
            return HealthWorkoutRecord(
                id: item.id,
                sourceName: item.sourceName,
                sport: Sport(rawValue: item.sport) ?? .other,
                activityName: item.activityName,
                sessionID: item.sessionID,
                start: start,
                durationSeconds: item.durationSeconds,
                distanceMeters: item.distanceMeters,
                activeEnergyKcal: item.activeEnergyKcal,
                heartRate: (item.heartRate ?? []).enumerated().map { index, bpm in
                    HeartRatePoint(offset: Double(index) * fixture.heartRateIntervalSeconds, bpm: bpm)
                },
                averagePowerWatts: item.averagePowerWatts,
                averageCadence: item.averageCadence,
                effortScore: item.effortScore
            )
        }
    }

    public func dailyMetrics(in interval: DateInterval) async throws -> [HealthDailyRecord] {
        fixture.days.compactMap { item in
            guard let day = date(dayOffset: item.dayOffset, minuteOfDay: 0), interval.contains(day) else { return nil }
            var record = HealthDailyRecord(date: day)
            record.restingHR = item.restingHR
            record.hrvSDNN = item.hrvSDNN
            record.sleepSeconds = item.sleepSeconds
            record.sleepCoreSeconds = item.sleepCoreSeconds
            record.sleepDeepSeconds = item.sleepDeepSeconds
            record.sleepREMSeconds = item.sleepREMSeconds
            record.sleepAwakeSeconds = item.sleepAwakeSeconds
            record.respiratoryRate = item.respiratoryRate
            record.steps = item.steps
            record.activeEnergyKcal = item.activeEnergyKcal
            record.vo2Max = item.vo2Max
            record.bodyMassKg = item.bodyMassKg
            return record
        }
    }

    private var startOfToday: Date { calendar.startOfDay(for: now) }

    private func date(dayOffset: Int, minuteOfDay: Int) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { return nil }
        return calendar.date(byAdding: .minute, value: minuteOfDay, to: day)
    }
}

public enum FixtureError: Error {
    case missingResource
}

struct Fixture: Decodable {
    struct Profile: Decodable {
        var ageYears: Int
        var biologicalSex: String
        var heightCm: Double
    }

    struct Workout: Decodable {
        var id: UUID
        var sourceName: String
        var sport: String
        var activityName: String
        var sessionID: UUID?
        /// Days before today (zero or negative).
        var dayOffset: Int
        var startMinute: Int
        var durationSeconds: Double
        var distanceMeters: Double?
        var activeEnergyKcal: Double?
        /// One value per `heartRateIntervalSeconds`; absent for summary-only workouts.
        var heartRate: [Double]?
        var averagePowerWatts: Double?
        var averageCadence: Double?
        var effortScore: Double?
    }

    struct Day: Decodable {
        var dayOffset: Int
        var restingHR: Double?
        var hrvSDNN: Double?
        var sleepSeconds: Double?
        var sleepCoreSeconds: Double?
        var sleepDeepSeconds: Double?
        var sleepREMSeconds: Double?
        var sleepAwakeSeconds: Double?
        var respiratoryRate: Double?
        var steps: Double?
        var activeEnergyKcal: Double?
        var vo2Max: Double?
        var bodyMassKg: Double?
    }

    var heartRateIntervalSeconds: Double
    var profile: Profile
    var workouts: [Workout]
    var days: [Day]
}
