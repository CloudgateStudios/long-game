import Analysis
import Foundation
import Models
import SwiftData
import Testing

@MainActor
@Suite struct StoreTests {
    @Test func aNewStoreStartsEmpty() throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = container.mainContext
        // Nothing is created on the user's behalf: no goal, no plan, no profile.
        #expect(try context.fetchCount(FetchDescriptor<Goal>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TrainingPlan>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AthleteProfile>()) == 0)
    }

    @Test func deletingAPlanCascadesToItsWorkouts() throws {
        // The context does not keep its container alive.
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = container.mainContext
        let plan = TrainingPlan(name: "Test", startDate: .now, endDate: .now)
        context.insert(plan)
        let session = PlannedWorkout(date: .now, sport: .run, sessionType: .long, targetDurationSeconds: 3600)
        session.plan = plan
        context.insert(session)
        try context.save()
        #expect(plan.workouts?.count == 1)

        context.delete(plan)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<PlannedWorkout>()) == 0)
    }

    @Test func profileReportsAgeNotDateOfBirth() throws {
        let profile = AthleteProfile()
        let calendar = Calendar(identifier: .gregorian)
        profile.dateOfBirth = DateComponents(calendar: calendar, year: 1988, month: 6, day: 15).date
        let before = try #require(DateComponents(calendar: calendar, year: 2026, month: 6, day: 14).date)
        let after = try #require(DateComponents(calendar: calendar, year: 2026, month: 6, day: 15).date)
        #expect(profile.age(on: before, calendar: calendar) == 37)
        #expect(profile.age(on: after, calendar: calendar) == 38)
    }
}

@MainActor
@Suite struct PlanTests {
    @Test func findsThePhaseAndSessionsForADay() throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = container.mainContext
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: start)! }

        let plan = TrainingPlan(name: "Test", startDate: day(0), endDate: day(27))
        context.insert(plan)
        for (kind, from, to) in [(PlanPhaseKind.build, 14, 27), (.base, 0, 13)] {
            let phase = PlanPhase(kind: kind, startDate: day(from), endDate: day(to))
            phase.plan = plan
            context.insert(phase)
        }
        let run = PlannedWorkout(date: day(13), sport: .run, sessionType: .long)
        run.plan = plan
        context.insert(run)
        try context.save()

        #expect(plan.sortedPhases.map(\.kind) == [.base, .build])
        // The last day of a phase belongs to it, at any time of day.
        #expect(plan.phase(on: day(13).addingTimeInterval(20 * 3600))?.kind == .base)
        #expect(plan.phase(on: day(14))?.kind == .build)
        #expect(plan.phase(on: day(28)) == nil)
        #expect(plan.workouts(on: day(13).addingTimeInterval(3600)).map(\.uuid) == [run.uuid])

        // Moving a session is just a date change.
        run.date = day(14)
        #expect(plan.workouts(on: day(13)).isEmpty)
        #expect(plan.workouts(on: day(14)).count == 1)
    }
}
