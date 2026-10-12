import Analysis
import Foundation
import Models
import SwiftData
import Testing

@MainActor
@Suite struct PlanReconcilerTests {
    let container: ModelContainer
    let context: ModelContext
    let calendar = Calendar.current
    let today: Date

    init() throws {
        container = try LongGameStore.makeContainer(mode: .inMemory)
        context = container.mainContext
        today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)).addingTimeInterval(12 * 3600)
    }

    func day(_ offset: Int, hour: Double = 0) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: today))!.addingTimeInterval(
            hour * 3600)
    }

    @discardableResult
    func plan(_ sport: Sport, day offset: Int, minutes: Double? = 60, type: SessionType = .easy) -> PlannedWorkout {
        let session = PlannedWorkout(
            date: day(offset), sport: sport, sessionType: type, targetDurationSeconds: minutes.map { $0 * 60 })
        context.insert(session)
        return session
    }

    @discardableResult
    func log(_ sport: Sport, day offset: Int, minutes: Double = 60, primary: Bool = true) -> CompletedWorkout {
        let workout = CompletedWorkout(
            externalID: UUID(), source: .healthKit, sport: sport, start: day(offset, hour: 7),
            durationSeconds: minutes * 60)
        workout.isPrimary = primary
        context.insert(workout)
        return workout
    }

    func reconcile() throws -> Int {
        try PlanReconciler.reconcile(in: context, now: today, calendar: calendar)
    }

    @Test func setsMatchesAndStatuses() throws {
        let done = plan(.run, day: -3)
        let partial = plan(.bike, day: -2, minutes: 100)
        let overdone = plan(.swim, day: -2, minutes: 30)
        let missed = plan(.run, day: -1)
        let upcoming = plan(.run, day: 2)
        let rest = plan(.run, day: -1, minutes: nil, type: .rest)
        log(.run, day: -3, minutes: 58)
        log(.bike, day: -2, minutes: 60)
        log(.swim, day: -2, minutes: 45)
        let unplanned = log(.strength, day: -1)

        #expect(try reconcile() == 4)
        #expect(done.status == .done)
        #expect(partial.status == .partial)
        #expect(overdone.status == .overdone)
        #expect(missed.status == .missed)
        #expect(upcoming.status == .planned)
        #expect(rest.status == .planned)
        #expect(rest.matchedWorkout == nil)
        #expect(unplanned.plannedWorkout == nil)
        #expect(partial.complianceRatio == 0.6)

        // Nothing changes on a second pass.
        #expect(try reconcile() == 0)
    }

    @Test func duplicatesAreNeverMatched() throws {
        let ride = plan(.bike, day: -1)
        let duplicate = log(.bike, day: -1, primary: false)
        #expect(try reconcile() == 1)
        #expect(ride.matchedWorkout == nil)
        #expect(ride.status == .missed)

        // Once it is the recording that counts, it matches.
        duplicate.isPrimary = true
        try reconcile()
        #expect(ride.matchedWorkout === duplicate)
    }

    @Test func movingASessionRematchesIt() throws {
        let run = plan(.run, day: -5)
        let workout = log(.run, day: -2)
        try reconcile()
        #expect(run.status == .missed)

        run.date = day(-2)
        try reconcile()
        #expect(run.matchedWorkout === workout)
        #expect(run.status == .done)
    }

    @Test func aDeletedWorkoutLeavesItsSessionMissed() throws {
        let run = plan(.run, day: -2)
        let workout = log(.run, day: -2)
        try reconcile()
        #expect(run.status == .done)

        context.delete(workout)
        try context.save()
        try reconcile()
        #expect(run.matchedWorkout == nil)
        #expect(run.status == .missed)
    }

    @Test func aManualMatchSurvivesAndFreesTheOtherSession() throws {
        let tuesday = plan(.run, day: -3)
        let friday = plan(.run, day: 0)
        let workout = log(.run, day: -3)
        try reconcile()
        #expect(tuesday.matchedWorkout === workout)

        // Three days apart is beyond automatic matching, but the user knows better.
        PlanReconciler.match(friday, to: workout)
        try reconcile()
        #expect(friday.matchedWorkout === workout)
        #expect(friday.status == .done)
        #expect(tuesday.matchedWorkout == nil)
        #expect(tuesday.status == .missed)
    }

    @Test func aManualUnmatchIsNotUndoneByTheNextPass() throws {
        let run = plan(.run, day: -2)
        let other = plan(.run, day: -1)
        let workout = log(.run, day: -2)
        try reconcile()

        PlanReconciler.unmatch(run)
        try reconcile()
        #expect(run.matchedWorkout == nil)
        #expect(run.status == .missed)
        // The workout stays unplanned rather than sliding onto the next day's session.
        #expect(workout.plannedWorkout == nil)
        #expect(other.status == .missed)

        try PlanReconciler.resetToAutomatic(run, in: context)
        try reconcile()
        #expect(run.matchedWorkout === workout)
    }

    @Test func weekComplianceLeavesOutRestDays() throws {
        let plan = TrainingPlan(name: "Test", startDate: day(-7), endDate: day(7))
        context.insert(plan)
        for session in [
            self.plan(.run, day: -2), self.plan(.bike, day: -1), self.plan(.run, day: 1),
            self.plan(.run, day: -1, minutes: nil, type: .rest),
        ] {
            session.plan = plan
        }
        log(.run, day: -2, minutes: 60)
        try reconcile()

        let week = plan.compliance(on: (-3...3).map { day($0) }, calendar: calendar)
        #expect(week.planned == 3)
        #expect(week.completed == 1)
        #expect(week.missed == 1)
        #expect(week.upcoming == 1)
        #expect(week.plannedLoad == 360)
        #expect(week.achievedLoad == 120)
    }
}
