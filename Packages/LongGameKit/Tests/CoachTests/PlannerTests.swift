import Analysis
import Foundation
import Models
import SwiftData
import Testing

@testable import Coach

@MainActor
@Suite struct CoachPlannerTests {
    let container: ModelContainer
    let context: ModelContext
    let calendar = Calendar.current
    let now: Date
    let goal: Goal

    init() throws {
        container = try LongGameStore.makeContainer(mode: .inMemory)
        context = container.mainContext
        now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)).addingTimeInterval(9 * 3600)
        goal = Goal(
            title: "Half Marathon", eventSport: .run, eventDistanceMeters: 21_097.5,
            targetDate: calendar.date(byAdding: .day, value: 27, to: now))
        context.insert(goal)
        let profile = AthleteProfile()
        profile.availabilityHours = [1, 1, 0, 1, 1, 2, 3]
        context.insert(profile)
    }

    func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    func text(_ offset: Int) -> String {
        day(offset).formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
    }

    var request: PlanRequest {
        PlanRequest(start: day(0), end: day(27), goalTitle: goal.title, goalDate: goal.targetDate)
    }

    func reply(sessions: [(Int, String, String, Double?)]) -> String {
        let items = sessions.map { offset, sport, type, minutes in
            "{\"date\":\"\(text(offset))\",\"sport\":\"\(sport)\",\"sessionType\":\"\(type)\",\"durationMinutes\":\(minutes.map { "\($0)" } ?? "null"),\"distanceKm\":null,\"intensity\":\"Z2\",\"instructions\":null}"
        }.joined(separator: ",")
        return
            "{\"summary\":\"Four weeks: two to build, one to sharpen, one to taper.\",\"phases\":[{\"kind\":\"build\",\"start\":\"\(text(0))\",\"end\":\"\(text(13))\"},{\"kind\":\"taper\",\"start\":\"\(text(14))\",\"end\":\"\(text(40))\"}],\"sessions\":[\(items)]}"
    }

    func planner(replying reply: String) -> (CoachPlanner, MockTransport) {
        let transport = MockTransport([
            .response(
                status: 200,
                lines: MockTransport.events(chunks: [String(reply.prefix(80)), String(reply.dropFirst(80))]))
        ])
        return (CoachPlanner(client: ClaudeClient(transport: transport, retryDelays: [])), transport)
    }

    @Test func aGeneratedPlanIsStoredAsADraft() async throws {
        let reply = reply(sessions: [
            (0, "run", "easy", 40), (1, "bike", "long", 90), (1, "strength", "strength", 30), (27, "run", "race", nil),
            (-3, "run", "easy", 30), (60, "run", "easy", 30),
        ])
        let (planner, transport) = planner(replying: reply)
        let progress = PlanProgress()
        let plan = try await planner.generate(
            request: request, goal: goal, model: "claude-opus-5-5", apiKey: "k", in: context, now: now,
            calendar: calendar
        ) { progress.values.append($0) }

        #expect(plan.isDraft)
        #expect(plan.origin == .generated)
        #expect(plan.goal === goal)
        #expect(plan.name == "Half Marathon Plan")
        #expect(plan.coachSummary.hasPrefix("Four weeks"))
        // Sessions outside the requested dates are dropped.
        #expect(plan.workouts?.count == 4)
        #expect(plan.workouts(on: day(1), calendar: calendar).map(\.sport) == [.bike, .strength])
        #expect(plan.workouts(on: day(27), calendar: calendar).first?.sessionType == .race)
        #expect(plan.workouts(on: day(27), calendar: calendar).first?.targetDurationSeconds == nil)
        // A phase running past the end is clipped to the plan.
        #expect(plan.sortedPhases.map(\.kind) == [.build, .taper])
        #expect(plan.sortedPhases.last?.endDate == day(27))
        #expect(
            progress.values.last
                == CoachPlanner.Progress(
                    summary: "Four weeks: two to build, one to sharpen, one to taper.", sessionCount: 6))

        // The request went out with the plan prompt, the plan schema and what was asked for.
        let body = try jsonBody(transport.requests.first)
        #expect(body["system"] as? String == CoachConfiguration.planPrompt)
        let config = try #require(body["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["summary", "phases", "sessions"])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let sent = try #require(messages.first?["content"] as? String)
        let payload = try JSONDecoder().decode(CoachPayload.self, from: Data(sent.utf8))
        #expect(
            payload.planRequest
                == .init(start: text(0), end: text(27), weeks: 4, goal: "Half Marathon", goalDate: text(27)))
        #expect(payload.profile.availabilityHoursMonToSun == [1, 1, 0, 1, 1, 2, 3])
        #expect(payload.reviewType == "planGeneration")

        // The request is kept with its cost, like a review.
        let record = try #require(try context.fetch(FetchDescriptor<CoachReview>()).first)
        #expect(record.trigger == .planGeneration)
        #expect(record.payloadJSON == sent)
        #expect(record.outputTokens == 340)
    }

    @Test func draftsStayOutOfMatchingAndTheCoachsView() async throws {
        let (planner, _) = planner(replying: reply(sessions: [(-1, "run", "easy", 40), (0, "run", "easy", 40)]))
        // Ask for a plan that starts yesterday, so one session is already in the past.
        let request = PlanRequest(start: day(-1), end: day(27))
        let plan = try await planner.generate(
            request: request, goal: nil, model: "m", apiKey: "k", in: context, now: now, calendar: calendar)
        let workout = CompletedWorkout(
            externalID: UUID(), source: .healthKit, sport: .run, start: day(-1).addingTimeInterval(7 * 3600),
            durationSeconds: 2400)
        context.insert(workout)

        try PlanReconciler.reconcile(in: context, now: now, calendar: calendar)
        #expect(workout.plannedWorkout == nil)
        #expect(plan.workouts?.allSatisfy { $0.status == .planned } == true)
        #expect(
            try CoachPayloadBuilder.build(in: context, trigger: .onDemand, now: now, calendar: calendar).payload.plan
                == nil)

        try PlanReconciler.acceptDraft(plan, in: context, calendar: calendar)
        try PlanReconciler.reconcile(in: context, now: now, calendar: calendar)
        #expect(workout.plannedWorkout != nil)
        #expect(
            try CoachPayloadBuilder.build(in: context, trigger: .onDemand, now: now, calendar: calendar).payload.plan?
                .sessions.count == 2)
    }

    @Test func aNewDraftReplacesTheLastOne() async throws {
        let (first, _) = planner(replying: reply(sessions: [(0, "run", "easy", 40)]))
        _ = try await first.generate(
            request: request, goal: goal, model: "m", apiKey: "k", in: context, now: now, calendar: calendar)
        let (second, _) = planner(replying: reply(sessions: [(1, "swim", "easy", 30), (2, "bike", "easy", 60)]))
        let plan = try await second.generate(
            request: request, goal: goal, model: "m", apiKey: "k", in: context, now: now, calendar: calendar)

        let plans = try context.fetch(FetchDescriptor<TrainingPlan>())
        #expect(plans.count == 1)
        #expect(plans.first === plan)
        #expect(try context.fetchCount(FetchDescriptor<PlannedWorkout>()) == 2)
    }

    @Test func acceptingReplacesTheOldPlanFromTheStartDate() async throws {
        let old = TrainingPlan(name: "Old", startDate: day(-20), endDate: day(40))
        context.insert(old)
        for (offset, kind) in [(-10, PlanPhaseKind.base), (10, .build)] {
            let phase = PlanPhase(kind: kind, startDate: day(offset - 10), endDate: day(offset + 9))
            context.insert(phase)
            phase.plan = old
        }
        for offset in [-5, 0, 6] {
            let session = PlannedWorkout(date: day(offset), sport: .run, sessionType: .easy)
            context.insert(session)
            session.plan = old
        }
        let later = TrainingPlan(name: "Later", startDate: day(10), endDate: day(50))
        context.insert(later)
        let finished = TrainingPlan(name: "Finished", startDate: day(-90), endDate: day(-30))
        context.insert(finished)
        try context.save()

        let (planner, _) = planner(replying: reply(sessions: [(0, "bike", "easy", 60)]))
        let draft = try await planner.generate(
            request: request, goal: goal, model: "m", apiKey: "k", in: context, now: now, calendar: calendar)
        // Until accepted, the old plan is untouched.
        #expect(old.workouts?.count == 3)

        try PlanReconciler.acceptDraft(draft, in: context, calendar: calendar)
        #expect(!draft.isDraft)
        // The running plan is folded in: its history carries over, its future is replaced.
        #expect(draft.startDate == day(-20))
        #expect(draft.endDate == day(27))
        #expect((draft.workouts ?? []).map(\.date).sorted() == [day(-5), day(0)])
        #expect(draft.workouts(on: day(0), calendar: calendar).map(\.sport) == [.bike])
        #expect(draft.sortedPhases.map(\.kind) == [.base, .build, .taper])
        #expect(draft.sortedPhases.first?.endDate == day(-1))
        #expect(draft.phase(on: day(-3), calendar: calendar)?.kind == .base)
        // A plan that starts later is replaced outright; one already finished is untouched.
        let names = Set(try context.fetch(FetchDescriptor<TrainingPlan>()).map(\.name))
        #expect(names == ["Finished", "Half Marathon Plan"])
        #expect(try context.fetchCount(FetchDescriptor<PlannedWorkout>()) == 2)
    }

    @Test func discardingADraftLeavesEverythingElseAlone() async throws {
        let existing = TrainingPlan(name: "Existing", startDate: day(-5), endDate: day(20))
        context.insert(existing)
        let (planner, _) = planner(replying: reply(sessions: [(0, "bike", "easy", 60)]))
        let draft = try await planner.generate(
            request: request, goal: goal, model: "m", apiKey: "k", in: context, now: now, calendar: calendar)
        try PlanReconciler.discardDraft(draft, in: context)
        #expect(try context.fetch(FetchDescriptor<TrainingPlan>()).map(\.name) == ["Existing"])
        #expect(try context.fetchCount(FetchDescriptor<PlannedWorkout>()) == 0)
        // An accepted plan cannot be discarded this way.
        try PlanReconciler.discardDraft(existing, in: context)
        #expect(try context.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
    }

    @Test func aPlanWithNoUsableSessionsIsRejected() async throws {
        let (planner, _) = planner(replying: reply(sessions: [(90, "run", "easy", 40)]))
        await #expect(throws: CoachError.malformed) {
            _ = try await planner.generate(
                request: request, goal: goal, model: "m", apiKey: "k", in: context, now: now, calendar: calendar)
        }
        #expect(try context.fetchCount(FetchDescriptor<TrainingPlan>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CoachReview>()) == 0)
    }
}

@MainActor
final class PlanProgress {
    var values: [CoachPlanner.Progress] = []
}
