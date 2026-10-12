import Analysis
import Foundation
import SwiftData

/// The dated record of the athlete's zones and thresholds, and what was in force on a day.
public enum ThresholdHistory {
    public struct Values: Sendable, Equatable {
        public var zoneBounds: [Double]?
        public var ftpWatts: Double?
    }

    /// Snapshots as plain values, so scoring thousands of workouts does not go back to the
    /// store for each one.
    public struct Timeline: Sendable {
        private let entries: [(day: Date, values: Values)]

        public init(_ snapshots: [ThresholdSnapshot]) {
            entries = snapshots.map { ($0.date, Values(zoneBounds: $0.zoneUpperBounds, ftpWatts: $0.ftpWatts)) }
        }

        /// The numbers in force on a `CalendarDay` stamp: the latest recorded on or before
        /// it. A number nobody had entered yet takes the first value it was later given, so
        /// workouts from before the athlete knew their FTP are still scored against one.
        public func values(on day: Date) -> Values {
            func pick<T>(_ value: KeyPath<Values, T?>) -> T? {
                entries.last { $0.day <= day && $0.values[keyPath: value] != nil }?.values[keyPath: value]
                    ?? entries.first { $0.values[keyPath: value] != nil }?.values[keyPath: value]
            }
            return Values(zoneBounds: pick(\.zoneBounds), ftpWatts: pick(\.ftpWatts))
        }
    }

    /// Every snapshot, oldest first.
    public static func snapshots(in context: ModelContext) throws -> [ThresholdSnapshot] {
        try context.fetch(FetchDescriptor<ThresholdSnapshot>()).sorted {
            ($0.date, $0.createdAt, $0.uuid.uuidString) < ($1.date, $1.createdAt, $1.uuid.uuidString)
        }
    }

    /// Records `zones` as of today when they differ from the latest snapshot, and returns
    /// every snapshot, oldest first. The caller saves.
    @discardableResult
    public static func record(
        _ zones: ResolvedZones, in context: ModelContext, now: Date = Date(), calendar: Calendar = .current
    ) throws -> [ThresholdSnapshot] {
        var all = try snapshots(in: context)
        // One snapshot a day. Two devices can each write today's before they have synced;
        // the later one wins on both.
        for (index, snapshot) in all.enumerated().reversed() where index + 1 < all.count {
            if snapshot.date == all[index + 1].date {
                context.delete(snapshot)
                all.remove(at: index)
            }
        }

        let latest = all.last
        let isRecorded =
            latest.map {
                $0.zoneUpperBounds == zones.bounds && $0.ftpWatts == zones.ftpWatts
                    && $0.thresholdRunPaceSecondsPerKm == zones.thresholdRunPaceSecondsPerKm
                    && $0.thresholdSwimPaceSecondsPer100m == zones.thresholdSwimPaceSecondsPer100m
            } ?? false
        let hasAnything =
            zones.bounds != nil || zones.ftpWatts != nil || zones.thresholdRunPaceSecondsPerKm != nil
            || zones.thresholdSwimPaceSecondsPer100m != nil
        guard !isRecorded, hasAnything || latest != nil else { return all }

        let today = CalendarDay.stamp(for: now, calendar: calendar)
        let snapshot: ThresholdSnapshot
        if let latest, latest.date >= today {
            // Several edits in one day are one change.
            snapshot = latest
        } else {
            snapshot = ThresholdSnapshot(date: now)
            snapshot.date = today
            snapshot.createdAt = now
            context.insert(snapshot)
            all.append(snapshot)
        }
        snapshot.zoneUpperBounds = zones.bounds
        snapshot.maxHR = zones.maxHR
        snapshot.restingHR = zones.restingHR
        snapshot.ftpWatts = zones.ftpWatts
        snapshot.thresholdRunPaceSecondsPerKm = zones.thresholdRunPaceSecondsPerKm
        snapshot.thresholdSwimPaceSecondsPer100m = zones.thresholdSwimPaceSecondsPer100m
        return all
    }
}
