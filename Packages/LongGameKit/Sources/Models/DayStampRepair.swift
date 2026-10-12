import Analysis
import Foundation
import SwiftData

/// Stores written before days became `CalendarDay` stamps hold local midnights in the day
/// fields. This rewrites any such value as the stamp for the day it meant. A stamp is
/// recognisable on sight, so running it again changes nothing, and it also catches old
/// records that arrive later from a device that has not been updated. It can be deleted
/// once no device holds a store from before the first Production release.
public enum DayStampRepair {
    /// Returns how many records changed. The caller saves.
    @discardableResult
    public static func run(in context: ModelContext, calendar: Calendar = .current) throws -> Int {
        var changed = 0
        func repaired(_ day: Date) -> Date? {
            guard !CalendarDay.isStamp(day) else { return nil }
            changed += 1
            return CalendarDay.stamp(for: day, calendar: calendar)
        }
        for session in try context.fetch(FetchDescriptor<PlannedWorkout>()) {
            if let day = repaired(session.date) { session.date = day }
        }
        for metrics in try context.fetch(FetchDescriptor<DailyMetrics>()) {
            if let day = repaired(metrics.date) { metrics.date = day }
        }
        for phase in try context.fetch(FetchDescriptor<PlanPhase>()) {
            if let day = repaired(phase.startDate) { phase.startDate = day }
            if let day = repaired(phase.endDate) { phase.endDate = day }
        }
        for plan in try context.fetch(FetchDescriptor<TrainingPlan>()) {
            if let day = repaired(plan.startDate) { plan.startDate = day }
            if let day = repaired(plan.endDate) { plan.endDate = day }
        }
        for goal in try context.fetch(FetchDescriptor<Goal>()) {
            if let day = goal.targetDate.flatMap(repaired) { goal.targetDate = day }
        }
        return changed
    }
}
