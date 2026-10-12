import Analysis
import Coach
import Foundation
import HealthIngest
import Models
import SwiftData
import Testing

/// Calls the real API with synthetic fixture data. Costs money, so it only runs when a
/// key is supplied: `LONGGAME_LIVE_KEY=... swift test --filter LiveCoachTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LONGGAME_LIVE_KEY"] != nil))
struct LiveCoachTests {
    @Test func aRealReviewComesBackWellFormed() async throws {
        let key = ProcessInfo.processInfo.environment["LONGGAME_LIVE_KEY"]
        let model = ProcessInfo.processInfo.environment["LONGGAME_LIVE_MODEL"] ?? CoachConfiguration.defaultModel
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = container.mainContext
        let calendar = Calendar.current
        let now = Date()

        try await HealthIngestor(modelContainer: container).sync(
            from: try FixtureHealthDataSource(now: now), state: InMemorySyncStateStore(), now: now)
        let today = calendar.startOfDay(for: now)
        let goal = Goal(
            title: "Half Marathon", eventSport: .run, eventDistanceMeters: 21_097.5,
            targetDate: calendar.date(byAdding: .day, value: 91, to: today))
        context.insert(goal)
        let plan = TrainingPlan(
            name: "Plan", startDate: calendar.date(byAdding: .day, value: -28, to: today)!,
            endDate: calendar.date(byAdding: .day, value: 28, to: today)!, goal: goal)
        context.insert(plan)
        for offset in -14...14 where offset % 2 == 0 {
            let session = PlannedWorkout(
                date: calendar.date(byAdding: .day, value: offset, to: today)!,
                sport: offset % 4 == 0 ? .run : .bike,
                sessionType: offset % 4 == 0 ? .easy : .long,
                targetDurationSeconds: offset % 4 == 0 ? 2700 : 5400
            )
            context.insert(session)
            session.plan = plan
        }
        try context.save()
        try PlanReconciler.reconcile(in: context, now: now, calendar: calendar)
        try LoadRecalculator.recalculate(in: context, now: now, calendar: calendar)

        let review = try await CoachReviewer().run(
            trigger: .onDemand, model: model, apiKey: key, in: context, now: now, calendar: calendar)

        #expect(!review.assessment.isEmpty)
        #expect((review.inputTokens ?? 0) > 1000)
        #expect((review.outputTokens ?? 0) > 0)
        let suggestions = review.suggestions ?? []
        // Every suggestion about an existing session resolved to a real one.
        for suggestion in suggestions where suggestion.action != .add {
            #expect(suggestion.targetWorkout != nil)
        }
        let cost = CoachConfiguration.cost(
            model: review.model, inputTokens: review.inputTokens ?? 0, outputTokens: review.outputTokens ?? 0)
        print(
            "LIVE model=\(review.model) input=\(review.inputTokens ?? 0) output=\(review.outputTokens ?? 0) cost=\(cost.map { String(format: "$%.3f", $0) } ?? "?") payloadChars=\(review.payloadJSON.count) flags=\(review.flags.count) suggestions=\(suggestions.map(\.action.rawValue))"
        )
        print("LIVE assessment: \(review.assessment)")
    }

    @Test func aRealPlanComesBackWellFormed() async throws {
        let key = ProcessInfo.processInfo.environment["LONGGAME_LIVE_KEY"]
        let model = ProcessInfo.processInfo.environment["LONGGAME_LIVE_MODEL"] ?? CoachConfiguration.defaultModel
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = container.mainContext
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        try await HealthIngestor(modelContainer: container).sync(
            from: try FixtureHealthDataSource(now: now), state: InMemorySyncStateStore(), now: now)
        try LoadRecalculator.recalculate(in: context, now: now, calendar: calendar)
        let profile = try #require(try context.fetch(FetchDescriptor<AthleteProfile>()).first)
        profile.availabilityHours = [1, 1.5, 1, 1, 0, 3, 2]
        let goalDate = calendar.date(byAdding: .day, value: 55, to: today)!
        let goal = Goal(title: "Half Marathon", eventSport: .run, eventDistanceMeters: 21_097.5, targetDate: goalDate)
        context.insert(goal)
        try context.save()

        let request = PlanRequest(start: today, end: goalDate, goalTitle: goal.title, goalDate: goalDate)
        let plan = try await CoachPlanner().generate(
            request: request, goal: goal, model: model, apiKey: key, in: context, now: now, calendar: calendar)

        let sessions = plan.workouts ?? []
        #expect(plan.isDraft)
        #expect(sessions.count > 20)
        #expect(!plan.sortedPhases.isEmpty)
        // Friday has zero hours available, so nothing should land on it.
        let onFriday = sessions.filter { calendar.component(.weekday, from: $0.day) == 6 }
        let hasRace = !plan.workouts(on: goalDate, calendar: calendar).filter { $0.sessionType == .race }.isEmpty
        let record = try #require(try context.fetch(FetchDescriptor<CoachReview>()).first)
        let cost = CoachConfiguration.cost(
            model: record.model, inputTokens: record.inputTokens ?? 0, outputTokens: record.outputTokens ?? 0)
        let weekly = Dictionary(grouping: sessions) { calendar.dateInterval(of: .weekOfYear, for: $0.day)!.start }
            .sorted { $0.key < $1.key }
            .map { Int($0.value.reduce(0) { $0 + ($1.targetDurationSeconds ?? 0) } / 60) }
        print(
            "LIVEPLAN model=\(record.model) input=\(record.inputTokens ?? 0) output=\(record.outputTokens ?? 0) cost=\(cost.map { String(format: "$%.3f", $0) } ?? "?") sessions=\(sessions.count) phases=\(plan.sortedPhases.map(\.kind.rawValue)) onFriday=\(onFriday.count) raceOnGoalDay=\(hasRace) weeklyMinutes=\(weekly)"
        )
    }

    @Test func aRealConversationRunsToolsAndReplaysHistory() async throws {
        let key = ProcessInfo.processInfo.environment["LONGGAME_LIVE_KEY"]
        let model = ProcessInfo.processInfo.environment["LONGGAME_LIVE_MODEL"] ?? CoachConfiguration.defaultModel
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = container.mainContext
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        try await HealthIngestor(modelContainer: container).sync(
            from: try FixtureHealthDataSource(now: now), state: InMemorySyncStateStore(), now: now)
        let goal = Goal(
            title: "Half Marathon", eventSport: .run, eventDistanceMeters: 21_097.5,
            targetDate: calendar.date(byAdding: .day, value: 91, to: today))
        context.insert(goal)
        let plan = TrainingPlan(
            name: "Plan", startDate: calendar.date(byAdding: .day, value: -28, to: today)!,
            endDate: calendar.date(byAdding: .day, value: 28, to: today)!, goal: goal)
        context.insert(plan)
        for offset in -14...14 where offset % 2 == 0 {
            let session = PlannedWorkout(
                date: calendar.date(byAdding: .day, value: offset, to: today)!, sport: offset % 4 == 0 ? .run : .bike,
                sessionType: offset % 4 == 0 ? .tempo : .long, targetDurationSeconds: offset % 4 == 0 ? 3000 : 5400)
            context.insert(session)
            session.plan = plan
        }
        try context.save()
        try PlanReconciler.reconcile(in: context, now: now, calendar: calendar)
        try LoadRecalculator.recalculate(in: context, now: now, calendar: calendar)

        let conversation = CoachConversation(kind: .discussion, date: now)
        context.insert(conversation)
        let chat = CoachChat()
        try await chat.send(
            "My left knee has been sore since yesterday's run. Can you ease the next week of running for me?",
            in: conversation, model: model, apiKey: key, context: context, now: now, calendar: calendar)
        let afterFirst = conversation.estimatedCost
        let cards = conversation.suggestions ?? []
        if let first = cards.first { try SuggestionApplier.accept(first, in: context, calendar: calendar) }
        try await chat.send(
            "Thanks, I accepted the first one. Anything else I should watch for?", in: conversation, model: model,
            apiKey: key, context: context, now: now, calendar: calendar)

        let transcript = CoachChat.transcript(of: conversation.messagesJSON)
        #expect(transcript.contains { if case .coach = $0 { true } else { false } })
        #expect(!cards.isEmpty)
        print(
            "LIVECHAT model=\(conversation.model) input=\(conversation.inputTokens) output=\(conversation.outputTokens) firstMessageCost=\(String(format: "$%.3f", afterFirst)) totalCost=\(String(format: "$%.3f", conversation.estimatedCost)) cards=\(cards.map(\.action.rawValue)) items=\(transcript.count)"
        )
        for item in transcript {
            if case .coach(_, let text) = item {
                print("LIVECHAT coach: \(text.replacingOccurrences(of: "\n", with: " ").prefix(400))")
            }
        }
    }
}
