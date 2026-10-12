import Analysis
import Foundation
import Models
import SwiftData

/// Runs one review end to end: build the payload, call the model, store the result.
public struct CoachReviewer: Sendable {
    private let client: ClaudeClient

    public init(client: ClaudeClient = ClaudeClient()) {
        self.client = client
    }

    /// Nothing is stored unless the model returns a complete, well-formed reply.
    /// `onAssessment` receives the assessment so far while it streams.
    @MainActor
    public func run(
        trigger: ReviewTrigger,
        model: String,
        apiKey: String?,
        planID: UUID? = nil,
        in context: ModelContext,
        now: Date = Date(),
        calendar: Calendar = .current,
        onAssessment: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> CoachReview {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.missingAPIKey
        }
        let built = try CoachPayloadBuilder.build(
            in: context, trigger: trigger, planID: planID, now: now, calendar: calendar)

        let message = try await client.send(
            apiKey: apiKey, model: model, system: CoachConfiguration.systemPrompt, user: built.json
        ) { text in
            if let partial = PartialJSON.string(forKey: "assessment", in: text) {
                await onAssessment(partial)
            }
        }
        guard let response = try? JSONDecoder().decode(CoachResponse.self, from: Data(message.text.utf8)) else {
            throw CoachError.malformed
        }
        return try Self.store(
            response, built: built, message: message, requestedModel: model, trigger: trigger, in: context, now: now,
            calendar: calendar)
    }

    @MainActor
    static func store(
        _ response: CoachResponse,
        built: BuiltPayload,
        message: ClaudeMessage,
        requestedModel: String,
        trigger: ReviewTrigger,
        in context: ModelContext,
        now: Date,
        calendar: Calendar
    ) throws -> CoachReview {
        let review = CoachReview(
            date: now,
            periodStart: built.periodStart,
            periodEnd: built.periodEnd,
            trigger: trigger,
            model: message.model.isEmpty ? requestedModel : message.model
        )
        review.payloadJSON = built.json
        review.assessment = response.assessment.trimmingCharacters(in: .whitespacesAndNewlines)
        review.title = SessionTitle.clean(response.title ?? "")
        review.flags = response.flags
        review.inputTokens = message.usage.inputTokens
        review.outputTokens = message.usage.outputTokens
        context.insert(review)
        SpendLedger.record(
            message.usage, kind: .review, sessionID: review.uuid, model: review.model, requestedModel: requestedModel,
            date: now, in: context)

        let sessions = try context.fetch(FetchDescriptor<PlannedWorkout>())
        let byUUID = Dictionary(sessions.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (index, suggestion) in response.suggestions.enumerated() {
            let record = PlanSuggestion(
                action: suggestion.action,
                proposedChangeJSON: String(decoding: try encoder.encode(suggestion), as: UTF8.self),
                rationale: suggestion.rationale
            )
            // Keep the model's order: most important first.
            record.createdAt = now.addingTimeInterval(Double(index) / 1000)
            context.insert(record)
            record.review = review
            let target = suggestion.sessionId.flatMap { built.sessionIDs[$0.lowercased()] }.flatMap { byUUID[$0] }
            record.targetWorkout = target
            record.targetSummary = target.map { SuggestionApplier.summary(of: $0, calendar: calendar) } ?? ""
        }
        try context.save()
        return review
    }
}

public enum SuggestionError: Error, Equatable {
    /// The session the suggestion was about has since been deleted.
    case sessionGone
    /// The suggestion does not say enough to act on.
    case incomplete
    case noPlan
}

/// Applies an accepted suggestion to the plan. Nothing here runs without the user
/// pressing Accept.
public enum SuggestionApplier {
    public static func proposal(of suggestion: PlanSuggestion) -> CoachSuggestion? {
        try? JSONDecoder().decode(CoachSuggestion.self, from: Data(suggestion.proposedChangeJSON.utf8))
    }

    public static func date(from text: String?, calendar: Calendar = .current) -> Date? {
        guard let text else { return nil }
        let style = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        return (try? style.parse(text)).map { calendar.startOfDay(for: $0) }
    }

    static func summary(of session: PlannedWorkout, calendar: Calendar) -> String {
        let style = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        var parts = [session.date.formatted(style), "\(session.sessionType.rawValue) \(session.sport.rawValue)"]
        if let seconds = session.targetDurationSeconds { parts.append("\(Int((seconds / 60).rounded())) min") }
        return parts.joined(separator: ", ")
    }

    @MainActor
    public static func accept(_ suggestion: PlanSuggestion, in context: ModelContext, calendar: Calendar = .current)
        throws
    {
        guard let proposal = proposal(of: suggestion) else { throw SuggestionError.incomplete }
        switch proposal.action {
        case .modify:
            guard let session = suggestion.targetWorkout else { throw SuggestionError.sessionGone }
            apply(proposal, to: session, calendar: calendar)
        case .move:
            guard let session = suggestion.targetWorkout else { throw SuggestionError.sessionGone }
            guard let date = date(from: proposal.date, calendar: calendar) else { throw SuggestionError.incomplete }
            session.date = date
        case .remove:
            guard let session = suggestion.targetWorkout else { throw SuggestionError.sessionGone }
            context.delete(session)
        case .add:
            guard let date = date(from: proposal.date, calendar: calendar), let sport = proposal.sport else {
                throw SuggestionError.incomplete
            }
            let plans = try context.fetch(FetchDescriptor<TrainingPlan>(sortBy: [SortDescriptor(\.startDate)]))
            guard let plan = plans.first(where: { $0.startDate <= date && date <= $0.endDate }) ?? plans.last else {
                throw SuggestionError.noPlan
            }
            let session = PlannedWorkout(date: date, sport: sport, sessionType: proposal.sessionType ?? .easy)
            context.insert(session)
            session.plan = plan
            apply(proposal, to: session, calendar: calendar)
        }
        suggestion.status = .accepted
        try context.save()
    }

    @MainActor
    public static func reject(_ suggestion: PlanSuggestion, in context: ModelContext) throws {
        suggestion.status = .rejected
        try context.save()
    }

    /// Fields left null in the proposal are left as they are.
    private static func apply(_ proposal: CoachSuggestion, to session: PlannedWorkout, calendar: Calendar) {
        if let date = date(from: proposal.date, calendar: calendar) { session.date = date }
        if let sport = proposal.sport { session.sport = sport }
        if let type = proposal.sessionType { session.sessionType = type }
        if let minutes = proposal.durationMinutes { session.targetDurationSeconds = minutes > 0 ? minutes * 60 : nil }
        if let km = proposal.distanceKm { session.targetDistanceMeters = km > 0 ? km * 1000 : nil }
        if let intensity = proposal.intensity { session.targetIntensity = intensity }
        if let instructions = proposal.instructions { session.instructions = instructions }
    }
}
