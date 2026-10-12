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
}
