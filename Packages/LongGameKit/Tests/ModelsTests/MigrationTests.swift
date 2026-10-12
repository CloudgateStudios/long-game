import Analysis
import Foundation
import Models
import SwiftData
import Testing

/// The models as they were in builds that only ever synced with CloudKit Development,
/// cut down to the fields that changed shape.
private enum Development {
    @Model final class PlannedWorkout {
        var uuid: UUID = UUID()
        var date: Date = Date()
        var instructions: String = ""
        var plan: TrainingPlan?
        init(date: Date, instructions: String) {
            self.date = date
            self.instructions = instructions
        }
    }

    @Model final class TrainingPlan {
        var uuid: UUID = UUID()
        var name: String = ""
        var startDate: Date = Date()
        var endDate: Date = Date()
        @Relationship(deleteRule: .cascade, inverse: \PlannedWorkout.plan) var workouts: [PlannedWorkout]? = []
        init(name: String, startDate: Date, endDate: Date) {
            self.name = name
            self.startDate = startDate
            self.endDate = endDate
        }
    }

    @Model final class DailyMetrics {
        var date: Date = Date()
        var restingHR: Double?
        init(date: Date, restingHR: Double) {
            self.date = date
            self.restingHR = restingHR
        }
    }

    @Model final class Goal {
        var uuid: UUID = UUID()
        var title: String = ""
        var targetDate: Date?
        var seedKey: String?
        init(title: String, targetDate: Date?) {
            self.title = title
            self.targetDate = targetDate
        }
    }

    static let schema = Schema([PlannedWorkout.self, TrainingPlan.self, DailyMetrics.self, Goal.self])
}

@MainActor
@Suite struct MigrationTests {
    let calendar = Calendar.current

    @Test func aDevelopmentStoreOpensAndKeepsItsDays() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "LongGame.store")
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

        do {
            let container = try ModelContainer(
                for: Development.schema,
                configurations: [ModelConfiguration(schema: Development.schema, url: url, cloudKitDatabase: .none)])
            let context = container.mainContext
            let plan = Development.TrainingPlan(name: "Spring", startDate: day(0), endDate: day(27))
            context.insert(plan)
            let session = Development.PlannedWorkout(date: day(3), instructions: "Steady")
            context.insert(session)
            session.plan = plan
            context.insert(Development.DailyMetrics(date: day(-1), restingHR: 51))
            let goal = Development.Goal(title: "Half Marathon", targetDate: day(90))
            goal.seedKey = "starter"
            context.insert(goal)
            try context.save()
        }

        let container = try ModelContainer(
            for: LongGameStore.schema, migrationPlan: LongGameMigrationPlan.self,
            configurations: [ModelConfiguration(schema: LongGameStore.schema, url: url, cloudKitDatabase: .none)])
        let context = container.mainContext
        // Renamed fields arrive holding the old local midnights until they are repaired.
        // Two on the plan and one each on the session, the day and the goal. A machine set
        // to UTC has nothing to repair: its midnights are stamps already.
        #expect(try DayStampRepair.run(in: context, calendar: calendar) == (CalendarDay.isStamp(today) ? 0 : 5))
        #expect(try DayStampRepair.run(in: context, calendar: calendar) == 0)
        try context.save()

        let plan = try #require(try context.fetch(FetchDescriptor<Models.TrainingPlan>()).first)
        #expect(plan.name == "Spring")
        #expect(plan.startDate == day(0))
        #expect(plan.endDate == day(27))
        let session = try #require(plan.workouts?.first)
        #expect(session.date == day(3))
        #expect(CalendarDay.isStamp(session.day))
        #expect(session.instructions == "Steady")
        #expect(session.orderInDay == 0)
        #expect(session.brickID == nil)
        let metrics = try #require(try context.fetch(FetchDescriptor<Models.DailyMetrics>()).first)
        #expect(metrics.date == day(-1))
        #expect(metrics.restingHR == 51)
        let goal = try #require(try context.fetch(FetchDescriptor<Models.Goal>()).first)
        #expect(goal.title == "Half Marathon")
        #expect(goal.targetDate == day(90))
    }

    @Test func sessionsOnADayFollowTheirOrder() throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = container.mainContext
        let plan = Models.TrainingPlan(name: "Test", startDate: .now, endDate: .now)
        context.insert(plan)
        let run = Models.PlannedWorkout(date: .now, sport: .run, sessionType: .easy)
        let bike = Models.PlannedWorkout(date: .now, sport: .bike, sessionType: .tempo)
        bike.createdAt = run.createdAt.addingTimeInterval(1)
        for session in [run, bike] {
            context.insert(session)
            session.plan = plan
        }
        #expect(plan.workouts(on: .now).map(\.sport) == [.run, .bike])

        // A brick: the run comes straight off the bike, ahead of anything else that day.
        let swim = Models.PlannedWorkout(date: .now, sport: .swim, sessionType: .easy)
        swim.createdAt = run.createdAt.addingTimeInterval(-1)
        context.insert(swim)
        swim.plan = plan
        run.follow(bike)
        #expect(plan.workouts(on: .now).map(\.sport) == [.swim, .bike, .run])
        #expect(run.brickLeader === bike)
        #expect(bike.brickLeader == nil)
        #expect(bike.isInBrick && run.isInBrick && !swim.isInBrick)

        // Moved to another day, the run is on its own again and so is the bike.
        run.date = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        #expect(!run.isInBrick && !bike.isInBrick)
        run.follow(bike)
        #expect(run.day == bike.day)
        #expect(run.isInBrick)

        run.follow(nil)
        #expect(run.brickID == nil)
        #expect(bike.brickID == nil)
    }
}
