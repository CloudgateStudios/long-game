import Analysis
import Foundation
import Models
import SwiftData

/// Asks the coach for a whole plan and stores it as a draft to review. The draft
/// changes nothing until it is accepted.
public struct CoachPlanner: Sendable {
    public struct Progress: Sendable, Equatable {
        public var summary: String
        public var sessionCount: Int
    }

    private let client: ClaudeClient

    public init(client: ClaudeClient = ClaudeClient()) {
        self.client = client
    }

    @MainActor
    public func generate(
        request: PlanRequest,
        goal: Goal?,
        model: String,
        apiKey: String?,
        in context: ModelContext,
        now: Date = Date(),
        calendar: Calendar = .current,
        onProgress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }
    ) async throws -> TrainingPlan {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.missingAPIKey
        }
        let built = try CoachPayloadBuilder.build(
            in: context, trigger: .planGeneration, planRequest: request, now: now, calendar: calendar)

        let message = try await client.send(
            apiKey: apiKey, model: model, system: CoachConfiguration.planPrompt, user: built.json, format: .plan
        ) { text in
            let summary = PartialJSON.string(forKey: "summary", in: text) ?? ""
            // Each session carries exactly one sessionType, so counting them counts sessions.
            await onProgress(
                Progress(summary: summary, sessionCount: text.components(separatedBy: "\"sessionType\"").count - 1))
        }
        guard let response = try? JSONDecoder().decode(PlanResponse.self, from: Data(message.text.utf8)) else {
            throw CoachError.malformed
        }
        return try Self.store(
            response, request: request, goal: goal, built: built, message: message, requestedModel: model, in: context,
            now: now, calendar: calendar)
    }

    @MainActor
    static func store(
        _ response: PlanResponse,
        request: PlanRequest,
        goal: Goal?,
        built: BuiltPayload,
        message: ClaudeMessage,
        requestedModel: String,
        in context: ModelContext,
        now: Date,
        calendar: Calendar
    ) throws -> TrainingPlan {
        let plan = try Self.makeDraft(
            response, start: request.start, end: request.end, goal: goal, in: context, now: now, calendar: calendar)

        // A record of the request, so "What Was Sent" and the cost are kept for plans too.
        let review = CoachReview(
            date: now, periodStart: built.periodStart, periodEnd: built.periodEnd, trigger: .planGeneration,
            model: message.model.isEmpty ? requestedModel : message.model)
        review.payloadJSON = built.json
        review.assessment = plan.coachSummary
        review.title = plan.name
        review.inputTokens = message.usage.inputTokens
        review.outputTokens = message.usage.outputTokens
        context.insert(review)
        SpendLedger.record(
            message.usage, kind: .planGeneration, sessionID: review.uuid, model: review.model,
            requestedModel: requestedModel, date: now, in: context)

        try context.save()
        return plan
    }

    /// Turns a plan the model wrote into a draft. Anything it placed outside the dates is
    /// dropped rather than trusted, and a plan with nothing usable is rejected. The caller saves.
    @MainActor
    static func makeDraft(
        _ response: PlanResponse,
        start: Date,
        end: Date,
        goal: Goal?,
        in context: ModelContext,
        now: Date,
        calendar: Calendar
    ) throws -> TrainingPlan {
        let start = calendar.startOfDay(for: start)
        let end = calendar.startOfDay(for: end)
        let sessions = response.sessions.compactMap { session -> (Date, PlanResponse.Session)? in
            guard let date = SuggestionApplier.date(from: session.date, calendar: calendar), date >= start, date <= end
            else { return nil }
            return (date, session)
        }
        guard start <= end, !sessions.isEmpty else { throw CoachError.malformed }

        // Only one draft at a time: a new one replaces the last.
        for stale in try context.fetch(FetchDescriptor<TrainingPlan>()) where stale.isDraft {
            context.delete(stale)
        }

        let plan = TrainingPlan(
            name: goal.map { "\($0.title) Plan" } ?? "Training Plan",
            startDate: start,
            endDate: end,
            origin: .generated,
            goal: goal
        )
        plan.isDraft = true
        plan.coachSummary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(plan)

        for phase in response.phases {
            guard let from = SuggestionApplier.date(from: phase.start, calendar: calendar),
                let to = SuggestionApplier.date(from: phase.end, calendar: calendar), from <= to, to >= start,
                from <= end
            else { continue }
            let record = PlanPhase(kind: phase.kind, startDate: max(from, start), endDate: min(to, end))
            context.insert(record)
            record.plan = plan
        }

        for (index, (date, session)) in sessions.enumerated() {
            let record = PlannedWorkout(
                date: date,
                sport: session.sport,
                sessionType: session.sessionType,
                targetDurationSeconds: session.durationMinutes.flatMap { $0 > 0 ? $0 * 60 : nil },
                targetDistanceMeters: session.distanceKm.flatMap { $0 > 0 ? $0 * 1000 : nil },
                targetIntensity: session.intensity ?? "",
                instructions: session.instructions ?? ""
            )
            // Keeps the model's order for sessions on the same day.
            record.createdAt = now.addingTimeInterval(Double(index) / 1000)
            context.insert(record)
            record.plan = plan
        }
        return plan
    }
}
