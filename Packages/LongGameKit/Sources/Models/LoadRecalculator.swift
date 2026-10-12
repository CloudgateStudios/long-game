import Analysis
import Foundation
import SwiftData

/// The zones in force and where they came from, for calculation and for display.
public struct ResolvedZones: Sendable, Equatable {
    public var maxHR: Double?
    public var maxHRSource: HeartRateZones.MaxSource?
    public var restingHR: Double?
    /// Upper bounds of zones 1–4; nil when there is nothing to derive zones from.
    public var bounds: [Double]?
    public var isOverridden = false
    public var ftpWatts: Double?
    public var thresholdRunPaceSecondsPerKm: Double?
    public var thresholdSwimPaceSecondsPer100m: Double?
    public var runTargets: RunTargetMode = .heartRate

    public init(
        maxHR: Double? = nil,
        maxHRSource: HeartRateZones.MaxSource? = nil,
        restingHR: Double? = nil,
        bounds: [Double]? = nil,
        isOverridden: Bool = false,
        ftpWatts: Double? = nil
    ) {
        self.maxHR = maxHR
        self.maxHRSource = maxHRSource
        self.restingHR = restingHR
        self.bounds = bounds
        self.isOverridden = isOverridden
        self.ftpWatts = ftpWatts
    }

    /// The athlete's numbers in the form structured workouts are exported against.
    public var thresholds: TrainingThresholds {
        TrainingThresholds(
            ftpWatts: ftpWatts, hrZoneUpperBounds: bounds, maxHR: maxHR,
            thresholdRunPaceSecondsPerKm: thresholdRunPaceSecondsPerKm)
    }
}

/// Works out zone times and training load for every completed workout and stores them,
/// so each device (and the coach) reads the same numbers.
public enum LoadRecalculator {
    public static func resolveZones(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) throws
        -> ResolvedZones
    {
        var profileDescriptor = FetchDescriptor<AthleteProfile>(sortBy: [SortDescriptor(\.createdAt)])
        profileDescriptor.fetchLimit = 1
        let profile = try context.fetch(profileDescriptor).first

        let observed = try context.fetch(FetchDescriptor<CompletedWorkout>()).compactMap(\.maxHR).max()
        let max = HeartRateZones.maxHeartRate(
            manual: profile?.maxHR, observed: observed, age: profile?.age(on: now, calendar: calendar))

        var resting = profile?.restingHRBaseline
        if resting == nil {
            let since = CalendarDay.stamp(
                for: calendar.date(byAdding: .day, value: -AnalysisConstants.baselineDays, to: now) ?? now,
                calendar: calendar)
            let recent = try context.fetch(FetchDescriptor<DailyMetrics>(predicate: #Predicate { $0.date >= since }))
                .compactMap(\.restingHR)
            if !recent.isEmpty { resting = recent.reduce(0, +) / Double(recent.count) }
        }

        let override = profile?.zoneUpperBoundsOverride
        var zones = ResolvedZones(
            maxHR: max?.value,
            maxHRSource: max?.source,
            restingHR: resting,
            bounds: HeartRateZones.resolve(override: override, maxHR: max?.value, restingHR: resting),
            isOverridden: override.map(HeartRateZones.isValid) ?? false,
            ftpWatts: profile?.ftpWatts
        )
        zones.thresholdRunPaceSecondsPerKm = profile?.thresholdRunPaceSecondsPerKm
        zones.thresholdSwimPaceSecondsPer100m = profile?.thresholdSwimPaceSecondsPer100m
        zones.runTargets = profile?.runTargets ?? .heartRate
        return zones
    }

    /// Returns how many workouts changed. Run after matching, since an unmeasured
    /// workout's estimate depends on the session it was matched to. Each workout is scored
    /// against the zones and FTP in force on its day, so today's numbers are recorded first.
    @discardableResult
    public static func recalculate(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) throws
        -> Int
    {
        let zones = try resolveZones(in: context, now: now, calendar: calendar)
        let history = ThresholdHistory.Timeline(
            try ThresholdHistory.record(zones, in: context, now: now, calendar: calendar))
        var changed = 0
        for workout in try context.fetch(FetchDescriptor<CompletedWorkout>()) {
            let inForce = history.values(on: CalendarDay.stamp(for: workout.start, calendar: calendar))
            let result = WorkoutLoad.compute(
                WorkoutLoad.Input(
                    sport: workout.sport,
                    durationSeconds: workout.durationSeconds,
                    heartRateHistogram: workout.heartRateHistogram,
                    averagePowerWatts: workout.averagePowerWatts,
                    sessionType: workout.plannedWorkout?.sessionType
                ),
                zoneBounds: inForce.zoneBounds,
                ftpWatts: inForce.ftpWatts
            )
            let confidence: LoadConfidence = result.method == .estimated ? .estimated : .measured
            // Write only real changes so iCloud is not asked to sync identical values.
            let sameLoad = workout.load.map { abs($0 - result.load) < 0.01 } ?? false
            if sameLoad, workout.zoneSeconds == result.zoneSeconds, workout.confidence == confidence { continue }
            workout.load = result.load
            workout.zoneSeconds = result.zoneSeconds
            workout.confidence = confidence
            changed += 1
        }
        if context.hasChanges { try context.save() }
        return changed
    }
}

extension CompletedWorkout {
    /// This workout in the load trend; nil for duplicates and before load is computed.
    public var loadEntry: LoadEntry? {
        guard isPrimary, let load else { return nil }
        return LoadEntry(date: start, sport: sport, load: load)
    }
}
