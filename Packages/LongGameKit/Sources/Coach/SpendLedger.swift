import Analysis
import Foundation
import Models
import SwiftData

/// Records what each API call cost. The caller saves.
public enum SpendLedger {
    /// Prices the usage at the model that answered, or at the one asked for when a
    /// fallback model with no known price stepped in. Calls with no tokens (the sample
    /// coach) are not recorded.
    @MainActor
    @discardableResult
    static func record(
        _ usage: ClaudeUsage,
        kind: CoachChargeKind,
        sessionID: UUID,
        model: String,
        requestedModel: String,
        date: Date,
        in context: ModelContext
    ) -> Double {
        guard usage.inputTokens + usage.outputTokens > 0 else { return 0 }
        let cost =
            CoachConfiguration.cost(model: model, usage: usage) ?? CoachConfiguration.cost(
                model: requestedModel, usage: usage) ?? 0
        context.insert(
            CoachCharge(
                date: date, kind: kind, sessionID: sessionID, model: model, inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens, cost: cost))
        return cost
    }

    /// Creates charges for reviews and conversations from before the ledger existed, and
    /// merges copies another device made of the same ones. Safe to run on every launch.
    @MainActor
    public static func backfill(in context: ModelContext) throws {
        var charges = try context.fetch(FetchDescriptor<CoachCharge>(sortBy: [SortDescriptor(\.date)]))
        var covered = Set(charges.map(\.sessionID))

        for review in try context.fetch(FetchDescriptor<CoachReview>()) where !covered.contains(review.uuid) {
            guard let input = review.inputTokens, let output = review.outputTokens, input + output > 0,
                let cost = CoachConfiguration.cost(model: review.model, inputTokens: input, outputTokens: output)
            else { continue }
            let charge = CoachCharge(
                date: review.date, kind: review.trigger == .planGeneration ? .planGeneration : .review,
                sessionID: review.uuid, model: review.model, inputTokens: input, outputTokens: output, cost: cost)
            charge.backfillKey = "review-\(review.uuid.uuidString)"
            context.insert(charge)
            charges.append(charge)
            covered.insert(review.uuid)
        }
        for conversation in try context.fetch(FetchDescriptor<CoachConversation>())
        where !covered.contains(conversation.uuid) {
            guard conversation.estimatedCost > 0 else { continue }
            // Earlier turns were not dated one by one, so the whole amount lands on the last activity.
            let charge = CoachCharge(
                date: conversation.updatedAt, kind: .conversation, sessionID: conversation.uuid,
                model: conversation.model,
                inputTokens: conversation.inputTokens, outputTokens: conversation.outputTokens,
                cost: conversation.estimatedCost)
            charge.backfillKey = "conversation-\(conversation.uuid.uuidString)"
            context.insert(charge)
            charges.append(charge)
            covered.insert(conversation.uuid)
        }

        // A reconstructed charge gives way to real ones for the same session, and to an
        // earlier copy of itself made on another device.
        let recorded = Set(charges.filter { $0.backfillKey == nil }.map(\.sessionID))
        var seen = Set<String>()
        for charge in charges.sorted(by: {
            ($0.backfillKey ?? "", $0.uuid.uuidString) < ($1.backfillKey ?? "", $1.uuid.uuidString)
        }) {
            guard let key = charge.backfillKey else { continue }
            if recorded.contains(charge.sessionID) || !seen.insert(key).inserted {
                context.delete(charge)
            }
        }
        if context.hasChanges { try context.save() }
    }
}
