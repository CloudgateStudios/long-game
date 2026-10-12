import Analysis
import Foundation
import Models
import SwiftData

/// Pulls records from a `HealthDataSource` and upserts them into the store, off the
/// main actor. Workouts are keyed by their external (HealthKit) UUID, days by date.
@ModelActor
public actor HealthIngestor {
    public struct Summary: Sendable, Equatable {
        public var workoutsInserted = 0
        public var workoutsUpdated = 0
        public var workoutsDeleted = 0
        public var daysUpserted = 0
    }

    /// Reads everything new since the last sync: a backfill the first time, then only
    /// changes. Safe to run repeatedly and from background delivery.
    @discardableResult
    public func sync(
        from source: any HealthDataSource,
        state: any SyncStateStore,
        now: Date = Date(),
        calendar: Calendar = .current,
        onProgress: @Sendable (SyncStep) -> Void = { _ in }
    ) async throws -> Summary {
        guard source.isAvailable else { return Summary() }
        let today = calendar.startOfDay(for: now)

        let backfillStart: Date
        if let stored = state.date(for: .backfillStart) {
            backfillStart = stored
        } else {
            backfillStart = calendar.date(byAdding: .day, value: -AnalysisConstants.backfillDays, to: today) ?? today
        }
        // Daily values such as sleep and HRV can arrive late, so re-read a few days.
        let dailyStart =
            state.date(for: .lastDailySync)
            .flatMap {
                calendar.date(
                    byAdding: .day, value: -AnalysisConstants.dailyMetricsLookbackDays, to: calendar.startOfDay(for: $0)
                )
            }
            .map { max($0, backfillStart) } ?? backfillStart

        onProgress(.readingProfile)
        let profile = try await source.profile()
        onProgress(.readingWorkouts(done: 0, total: 0))
        let changes = try await source.workoutChanges(since: state.data(for: .workoutAnchor), from: backfillStart) {
            done, total in
            onProgress(.readingWorkouts(done: done, total: total))
        }
        onProgress(.readingDailyMetrics)
        let daily = try await source.dailyMetrics(in: DateInterval(start: dailyStart, end: max(now, dailyStart)))

        onProgress(.saving)
        var summary = Summary()
        try apply(profile)
        try delete(changes.deletedIDs, summary: &summary)
        try upsert(changes.upserted, source: source.workoutSource, summary: &summary)
        try resolveDuplicates(around: changes.upserted)
        try upsert(daily, calendar: calendar, summary: &summary)
        try modelContext.save()

        // Only move the markers once the store has the data.
        state.set(backfillStart, for: .backfillStart)
        state.set(changes.anchor, for: .workoutAnchor)
        state.set(now, for: .lastDailySync)
        return summary
    }

    private func apply(_ record: HealthProfileRecord) throws {
        var descriptor = FetchDescriptor<AthleteProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        let profile: AthleteProfile
        if let existing = try modelContext.fetch(descriptor).first {
            profile = existing
        } else {
            profile = AthleteProfile()
            modelContext.insert(profile)
        }
        // Health characteristics fill gaps; they never overwrite what is already there.
        if profile.dateOfBirth == nil { profile.dateOfBirth = record.dateOfBirth }
        if profile.biologicalSex == nil { profile.biologicalSex = record.biologicalSex }
        if profile.heightCm == nil { profile.heightCm = record.heightCm }
        if profile.ftpWatts == nil { profile.ftpWatts = record.ftpWatts }
        // Weight changes over time, so the latest reading wins.
        if let weight = record.weightKg, profile.weightKg != weight { profile.weightKg = weight }
    }

    private func delete(_ ids: [UUID], summary: inout Summary) throws {
        guard !ids.isEmpty else { return }
        let optionalIDs: [UUID?] = ids
        // A deleted multisport workout takes all of its legs with it.
        let doomed = try modelContext.fetch(
            FetchDescriptor<CompletedWorkout>(
                predicate: #Predicate { ids.contains($0.externalID) || optionalIDs.contains($0.sessionID) }
            ))
        for workout in doomed {
            modelContext.delete(workout)
        }
        summary.workoutsDeleted += doomed.count
    }

    private func upsert(_ records: [HealthWorkoutRecord], source: WorkoutSource, summary: inout Summary) throws {
        guard !records.isEmpty else { return }
        let ids = records.map(\.id)
        let existing = try modelContext.fetch(
            FetchDescriptor<CompletedWorkout>(predicate: #Predicate { ids.contains($0.externalID) })
        )
        var byID = Dictionary(existing.map { ($0.externalID, $0) }, uniquingKeysWith: { first, _ in first })

        for record in records {
            let workout: CompletedWorkout
            if let found = byID[record.id] {
                workout = found
                summary.workoutsUpdated += 1
            } else {
                workout = CompletedWorkout(
                    externalID: record.id,
                    source: source,
                    sport: record.sport,
                    start: record.start,
                    durationSeconds: record.durationSeconds
                )
                modelContext.insert(workout)
                byID[record.id] = workout
                summary.workoutsInserted += 1
            }
            workout.sourceName = record.sourceName
            workout.sport = record.sport
            workout.activityName = record.activityName
            workout.sessionID = record.sessionID
            workout.start = record.start
            workout.durationSeconds = record.durationSeconds
            workout.distanceMeters = record.distanceMeters
            workout.activeEnergyKcal = record.activeEnergyKcal
            workout.averagePowerWatts = record.averagePowerWatts
            workout.averageCadence = record.averageCadence
            workout.effortScore = record.effortScore

            let heartRate = HeartRateHistogram.summarize(record.heartRate, duration: record.durationSeconds)
            workout.averageHR = heartRate?.average
            workout.maxHR = heartRate?.max
            workout.heartRateHistogram = heartRate?.bins
            // Without heart-rate samples, load can only be estimated from duration.
            workout.confidence = heartRate == nil ? .estimated : .measured
        }
    }

    /// Re-runs the duplicate rule over every stored workout near the ones that changed.
    private func resolveDuplicates(around records: [HealthWorkoutRecord]) throws {
        guard let earliest = records.map(\.start).min(), let latest = records.map(\.end).max() else { return }
        // A day either side comfortably covers any workout that could overlap.
        let from = earliest.addingTimeInterval(-86_400)
        let to = latest.addingTimeInterval(86_400)
        let nearby = try modelContext.fetch(
            FetchDescriptor<CompletedWorkout>(predicate: #Predicate { $0.start >= from && $0.start <= to })
        )
        let primary = DuplicateResolver.resolve(nearby.map(\.sessionCandidate))
        for workout in nearby {
            let isPrimary = primary[workout.externalID] ?? true
            if workout.isPrimary != isPrimary { workout.isPrimary = isPrimary }
        }
    }

    private func upsert(_ records: [HealthDailyRecord], calendar: Calendar, summary: inout Summary) throws {
        let stamps = records.map { CalendarDay.stamp(for: $0.date, calendar: calendar) }
        guard let first = stamps.min(), let last = stamps.max() else { return }
        let existing = try modelContext.fetch(
            FetchDescriptor<DailyMetrics>(predicate: #Predicate { $0.day >= first && $0.day <= last })
        )
        var byDay = Dictionary(existing.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })

        for (record, stamp) in zip(records, stamps) {
            let day: DailyMetrics
            if let found = byDay[stamp] {
                day = found
            } else {
                day = DailyMetrics(date: record.date)
                day.day = stamp
                modelContext.insert(day)
                byDay[stamp] = day
            }
            day.restingHR = record.restingHR
            day.hrvSDNN = record.hrvSDNN
            day.sleepSeconds = record.sleepSeconds
            day.sleepCoreSeconds = record.sleepCoreSeconds
            day.sleepDeepSeconds = record.sleepDeepSeconds
            day.sleepREMSeconds = record.sleepREMSeconds
            day.sleepAwakeSeconds = record.sleepAwakeSeconds
            day.respiratoryRate = record.respiratoryRate
            day.steps = record.steps
            day.activeEnergyKcal = record.activeEnergyKcal
            day.vo2Max = record.vo2Max
            day.bodyMassKg = record.bodyMassKg
            summary.daysUpserted += 1
        }
    }
}

extension CompletedWorkout {
    /// This workout as the duplicate rule sees it.
    public var sessionCandidate: SessionCandidate {
        SessionCandidate(
            id: externalID,
            sport: sport,
            start: start,
            duration: durationSeconds,
            hasPower: averagePowerWatts != nil,
            hasHeartRate: averageHR != nil,
            isFITImport: source == .fitImport,
            isManualPrimary: isPrimaryManuallySet && isPrimary
        )
    }
}
