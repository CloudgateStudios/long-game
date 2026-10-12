import Analysis
import Coach
import Foundation
import Models
import SwiftData

/// A plan shaped like the synthetic workouts, so matching and compliance have something
/// to show in the simulator. Fixture mode only; never created against real data.
enum SamplePlan {
    static let name = "Sample Plan"

    static func seedIfNeeded(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        guard (try? context.fetchCount(FetchDescriptor<TrainingPlan>())) == 0 else { return }
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }

        // The simulator gets a goal to plan toward; a real device starts with none.
        let goal = Goal(
            title: "Sample Half Marathon", type: .event, eventSport: .run, eventDistanceMeters: 21_097.5,
            targetDate: day(90), priority: .a)
        context.insert(goal)
        let plan = TrainingPlan(name: name, startDate: day(-28), endDate: day(13), goal: goal)
        context.insert(plan)
        for (kind, from, to) in [(PlanPhaseKind.base, -28, -1), (.build, 0, 13)] {
            let phase = PlanPhase(kind: kind, startDate: day(from), endDate: day(to))
            context.insert(phase)
            phase.plan = plan
        }

        // The fixture repeats a seven-day pattern in which today is the second day.
        let week: [[(Sport, SessionType, Double, String)]] = [
            [(.swim, .easy, 45, "Z2")],
            [(.run, .intervals, 45, "6 × 3 min hard"), (.strength, .strength, 35, "")],
            [(.bike, .tempo, 60, "Z3")],
            [(.run, .easy, 40, "Z2")],
            [(.strength, .strength, 25, "")],
            [(.bike, .long, 130, "Z2")],
            [(.run, .long, 80, "Z2")],
        ]
        for offset in -28...13 {
            for (sport, type, minutes, intensity) in week[((offset + 1) % 7 + 7) % 7] {
                let session = PlannedWorkout(
                    date: day(offset),
                    sport: sport,
                    sessionType: type,
                    targetDurationSeconds: minutes * 60,
                    targetIntensity: intensity
                )
                context.insert(session)
                session.plan = plan
            }
        }
        try? context.save()
    }

    /// A canned review so the suggestion screens have something to show without an API
    /// key. Labelled as a sample; fixture mode only.
    static func seedReviewIfNeeded(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        guard (try? context.fetchCount(FetchDescriptor<CoachReview>())) == 0,
            let plan = (try? context.fetch(FetchDescriptor<TrainingPlan>()))?.first(where: { $0.name == name })
        else { return }
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        let style = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()

        let review = CoachReview(
            date: now, periodStart: day(-28), periodEnd: today, trigger: .onDemand, model: "sample")
        review.assessment =
            "Sample review, not written by the coach. It is here so the suggestion screens can be tried in the simulator.\n\nConsistency has been good and load is steady. The long ride is carrying most of the week."
        review.flags = ["Sample flag: two short nights this week."]
        review.payloadJSON =
            (try? CoachPayloadBuilder.build(in: context, trigger: .onDemand, now: now, calendar: calendar).json) ?? "{}"
        context.insert(review)

        let proposals: [(CoachSuggestion, PlannedWorkout?)] = [
            (
                CoachSuggestion(
                    action: .modify, sessionType: .easy, durationMinutes: 45, intensity: "Z2",
                    rationale: "Sample: ease this one back after two short nights."),
                plan.workouts(on: day(2), calendar: calendar).first
            ),
            (
                CoachSuggestion(
                    action: .move, date: day(6).formatted(style),
                    rationale: "Sample: leave a day between the long ride and the long run."),
                plan.workouts(on: day(5), calendar: calendar).first
            ),
            (
                CoachSuggestion(
                    action: .add, date: day(4).formatted(style), sport: .swim, sessionType: .recovery,
                    durationMinutes: 30, rationale: "Sample: an easy swim keeps the week aerobic without more impact."),
                nil
            ),
            (
                CoachSuggestion(action: .remove, rationale: "Sample: drop this to make room for recovery."),
                plan.workouts(on: day(3), calendar: calendar).first
            ),
        ]
        for (index, (proposal, target)) in proposals.enumerated() {
            guard let data = try? JSONEncoder().encode(proposal) else { continue }
            let suggestion = PlanSuggestion(
                action: proposal.action, proposedChangeJSON: String(decoding: data, as: UTF8.self),
                rationale: proposal.rationale)
            suggestion.createdAt = now.addingTimeInterval(Double(index) / 1000)
            context.insert(suggestion)
            suggestion.review = review
            suggestion.targetWorkout = target
            suggestion.targetSummary =
                target.map { "\($0.date.formatted(style)), \($0.sessionType.rawValue) \($0.sport.rawValue)" } ?? ""
        }
        try? context.save()
    }

    /// A canned draft so the review-and-accept screens can be tried without an API key.
    /// Created once, so discarding it does not bring it back. Fixture mode only.
    static func seedDraftIfNeeded(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        let key = "fixture.didSeedDraft"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }

        let draft = TrainingPlan(name: "Sample Draft", startDate: day(1), endDate: day(21), origin: .generated)
        draft.isDraft = true
        draft.coachSummary =
            "Sample draft, not written by the coach. It is here so reviewing and accepting a generated plan can be tried in the simulator.\n\nThree weeks: two building, one easier."
        context.insert(draft)
        for (kind, from, to) in [(PlanPhaseKind.build, 1, 14), (.recovery, 15, 21)] {
            let phase = PlanPhase(kind: kind, startDate: day(from), endDate: day(to))
            context.insert(phase)
            phase.plan = draft
        }
        let week: [(Int, Sport, SessionType, Double, String)] = [
            (0, .run, .easy, 40, "Z2"), (1, .swim, .easy, 40, "Z2"), (2, .bike, .tempo, 60, "Z3"),
            (3, .run, .intervals, 45, "5 × 3 min at Z4"), (5, .bike, .long, 120, "Z2"), (6, .run, .long, 75, "Z2"),
        ]
        for start in stride(from: 1, through: 15, by: 7) {
            for (offset, sport, type, minutes, intensity) in week {
                let scale = start == 15 ? 0.7 : 1.0
                let session = PlannedWorkout(
                    date: day(start + offset), sport: sport, sessionType: type,
                    targetDurationSeconds: (minutes * scale).rounded() * 60, targetIntensity: intensity)
                context.insert(session)
                session.plan = draft
            }
        }
        try? context.save()
    }

    /// A canned conversation so the chat screen can be looked at without an API key.
    /// Created once. Fixture mode only.
    static func seedConversationIfNeeded(in context: ModelContext, now: Date = Date()) {
        let key = "fixture.didSeedConversation"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        func message(_ role: String, _ blocks: [JSONValue]) -> JSONValue {
            .object(["role": .string(role), "content": .array(blocks)])
        }
        let conversation = CoachConversation(kind: .discussion, date: now)
        conversation.title = "Sample conversation"
        conversation.model = "sample"
        conversation.messagesJSON =
            JSONValue.array([
                message("user", [.text("My legs felt heavy on Sunday's run. Should I change anything this week?")]),
                message(
                    "assistant",
                    [
                        .text(
                            "Sample reply, not written by the coach. It is here so the chat screen can be looked at in the simulator.\n\nSunday ran long against its target, so heavy legs make sense. I'd keep the week but take Tuesday easier."
                        )
                    ]),
            ]).text
        context.insert(conversation)
        try? context.save()
    }
}
