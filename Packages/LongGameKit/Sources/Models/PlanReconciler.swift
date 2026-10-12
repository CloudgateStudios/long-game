import Analysis
import Foundation
import SwiftData

extension PlannedWorkout {
    public var isRest: Bool { sessionType == .rest }

    public var session: PlannedSession {
        PlannedSession(
            id: uuid,
            date: date,
            sport: sport,
            sessionType: sessionType,
            targetDurationSeconds: targetDurationSeconds,
            targetDistanceMeters: targetDistanceMeters
        )
    }

    /// Completed ÷ target for the matched workout, when both exist.
    public var complianceRatio: Double? {
        matchedWorkout.flatMap { Compliance.ratio(planned: session, completed: $0.session) }
    }

    public var outcome: SessionOutcome {
        SessionOutcome(planned: session, matched: matchedWorkout?.session, status: status)
    }
}

extension CompletedWorkout {
    public var session: CompletedSession {
        CompletedSession(
            id: externalID,
            start: start,
            sport: sport,
            durationSeconds: durationSeconds,
            distanceMeters: distanceMeters,
            load: load
        )
    }
}

extension TrainingPlan {
    /// Compliance for the planned sessions on the given days, rest days excluded.
    public func compliance(on days: [Date], calendar: Calendar = .current) -> WeekCompliance {
        WeekCompliance(days.flatMap { workouts(on: $0, calendar: calendar) }.filter { !$0.isRest }.map(\.outcome))
    }
}

/// Keeps planned sessions, their matched workouts and their statuses in step with the
/// data. Deterministic, so every device reaches the same answer from the same records.
public enum PlanReconciler {
    /// Re-runs matching and compliance. Returns how many sessions changed.
    @discardableResult
    public static func reconcile(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) throws
        -> Int
    {
        // Sessions in a draft plan are proposals, not commitments.
        let planned = try context.fetch(FetchDescriptor<PlannedWorkout>()).filter { $0.plan?.isDraft != true }
        guard let first = planned.map(\.date).min(), let last = planned.map(\.date).max() else { return 0 }
        let from = first.addingTimeInterval(-2 * 86_400)
        let to = last.addingTimeInterval(3 * 86_400)
        let completed = try context.fetch(
            FetchDescriptor<CompletedWorkout>(predicate: #Predicate { $0.start >= from && $0.start <= to })
        )

        // Sessions matched or un-matched by hand keep whatever they have.
        let automatic = planned.filter { !$0.isManualMatch }
        let heldByHand = Set(planned.filter(\.isManualMatch).compactMap { $0.matchedWorkout?.externalID })
        let candidates = completed.filter { $0.isPrimary && !$0.isMatchLocked && !heldByHand.contains($0.externalID) }
        let matches = PlanMatcher.match(
            planned: automatic.filter { !$0.isRest }.map(\.session),
            completed: candidates.map(\.session),
            calendar: calendar
        )
        let byID = Dictionary(candidates.map { ($0.externalID, $0) }, uniquingKeysWith: { first, _ in first })

        var changed = Set<UUID>()
        // Release first, then assign, so a workout moving between sessions is never held twice.
        for session in automatic where session.matchedWorkout?.externalID != matches[session.uuid] {
            if session.matchedWorkout != nil { session.matchedWorkout = nil }
            changed.insert(session.uuid)
        }
        for session in automatic {
            guard let id = matches[session.uuid], session.matchedWorkout == nil else { continue }
            session.matchedWorkout = byID[id]
        }

        for session in planned {
            let status: PlannedStatus =
                session.isRest
                ? .planned
                : Compliance.status(
                    planned: session.session, matched: session.matchedWorkout?.session, today: now, calendar: calendar)
            if session.status != status {
                session.status = status
                changed.insert(session.uuid)
            }
        }
        if context.hasChanges { try context.save() }
        return changed.count
    }

    /// Pins a session to a workout chosen by the user, replacing any match either had.
    public static func match(_ session: PlannedWorkout, to workout: CompletedWorkout) {
        if let previous = workout.plannedWorkout, previous !== session {
            previous.matchedWorkout = nil
        }
        session.matchedWorkout = workout
        session.isManualMatch = true
        workout.isMatchLocked = true
    }

    /// Removes a match and stops automatic matching from putting it back.
    public static func unmatch(_ session: PlannedWorkout) {
        session.matchedWorkout?.isMatchLocked = true
        session.matchedWorkout = nil
        session.isManualMatch = true
    }

    /// Hands a session back to automatic matching, along with the workout it holds and
    /// any nearby workout of the same sport that was un-matched by hand.
    public static func resetToAutomatic(_ session: PlannedWorkout, in context: ModelContext) throws {
        session.matchedWorkout?.isMatchLocked = false
        session.isManualMatch = false

        let reach = Double(AnalysisConstants.matchDayTolerance + 1) * 86_400
        let from = session.date.addingTimeInterval(-reach)
        let to = session.date.addingTimeInterval(reach + 86_400)
        let sportRaw = session.sportRaw
        let released = try context.fetch(
            FetchDescriptor<CompletedWorkout>(
                predicate: #Predicate {
                    $0.isMatchLocked && $0.sportRaw == sportRaw && $0.start >= from && $0.start <= to
                }
            ))
        for workout in released where workout.plannedWorkout == nil {
            workout.isMatchLocked = false
        }
    }

    // MARK: Drafts

    /// Makes a draft the real plan from its start date. A plan already running on that
    /// date is folded into it: its earlier sessions and phases carry over as history, and
    /// everything it had from that date on is replaced. Plans that had already finished
    /// are left alone.
    public static func acceptDraft(_ draft: TrainingPlan, in context: ModelContext, calendar: Calendar = .current)
        throws
    {
        let start = calendar.startOfDay(for: draft.startDate)
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        for plan in try context.fetch(FetchDescriptor<TrainingPlan>()) where plan !== draft && !plan.isDraft {
            guard calendar.startOfDay(for: plan.endDate) >= start else { continue }
            for session in plan.workouts ?? [] where calendar.startOfDay(for: session.date) < start {
                session.plan = draft
            }
            for phase in plan.phases ?? [] where calendar.startOfDay(for: phase.startDate) < start {
                if calendar.startOfDay(for: phase.endDate) >= start { phase.endDate = dayBefore }
                phase.plan = draft
            }
            if plan.startDate < draft.startDate { draft.startDate = plan.startDate }
            if draft.goal == nil { draft.goal = plan.goal }
            // What is left on the old plan is exactly what the draft replaces.
            context.delete(plan)
        }
        draft.isDraft = false
        try context.save()
    }

    public static func discardDraft(_ draft: TrainingPlan, in context: ModelContext) throws {
        guard draft.isDraft else { return }
        context.delete(draft)
        try context.save()
    }
}
