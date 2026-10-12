import Analysis
import Foundation
import SwiftData

@Model
public final class CoachReview {
    public var uuid: UUID = UUID()
    public var date: Date = Date()
    public var periodStart: Date = Date()
    public var periodEnd: Date = Date()
    public var triggerRaw: String = ReviewTrigger.onDemand.rawValue
    /// The exact JSON sent to the model, shown on the "What was sent" screen.
    @Attribute(.allowsCloudEncryption) public var payloadJSON: String = ""
    public var model: String = ""
    @Attribute(.allowsCloudEncryption) public var assessment: String = ""
    @Attribute(.allowsCloudEncryption) public var flags: [String] = []
    /// A short name for the review: suggested by the coach, editable by the user.
    @Attribute(.allowsCloudEncryption) public var title: String = ""
    /// Tokens billed for this review, as reported by the API.
    public var inputTokens: Int?
    public var outputTokens: Int?

    @Relationship(deleteRule: .cascade, inverse: \PlanSuggestion.review)
    public var suggestions: [PlanSuggestion]? = []

    public init(date: Date = Date(), periodStart: Date, periodEnd: Date, trigger: ReviewTrigger, model: String) {
        self.date = date
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.triggerRaw = trigger.rawValue
        self.model = model
    }

    public var trigger: ReviewTrigger {
        get { ReviewTrigger(rawValue: triggerRaw) ?? .onDemand }
        set { triggerRaw = newValue.rawValue }
    }
}

@Model
public final class PlanSuggestion {
    public var uuid: UUID = UUID()
    public var actionRaw: String = SuggestionAction.modify.rawValue
    /// The proposed new values as JSON; decoded by the Coach module.
    @Attribute(.allowsCloudEncryption) public var proposedChangeJSON: String = ""
    @Attribute(.allowsCloudEncryption) public var rationale: String = ""
    public var statusRaw: String = SuggestionStatus.pending.rawValue
    public var createdAt: Date = Date()
    /// The targeted session as it was when suggested, kept so the history still reads
    /// after the session is changed or removed.
    @Attribute(.allowsCloudEncryption) public var targetSummary: String = ""

    public var review: CoachReview?
    /// Set instead of `review` when the suggestion came out of a conversation.
    public var conversation: CoachConversation?
    /// The tool call that produced it, so the chat can show it in the right place.
    public var sourceID: String = ""
    /// Nil when the suggestion proposes a new session.
    public var targetWorkout: PlannedWorkout?

    public init(action: SuggestionAction, proposedChangeJSON: String, rationale: String) {
        self.actionRaw = action.rawValue
        self.proposedChangeJSON = proposedChangeJSON
        self.rationale = rationale
    }

    public var action: SuggestionAction {
        get { SuggestionAction(rawValue: actionRaw) ?? .modify }
        set { actionRaw = newValue.rawValue }
    }

    public var status: SuggestionStatus {
        get { SuggestionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
}

/// A back-and-forth with the coach. The history is stored exactly as exchanged with the
/// API, because the model's replies must be sent back unaltered on every later turn.
@Model
public final class CoachConversation {
    public var uuid: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var kindRaw: String = ConversationKind.discussion.rawValue
    @Attribute(.allowsCloudEncryption) public var title: String = ""
    /// The title was suggested by the coach or typed by the user, so it is left alone.
    /// Until then it is just the opening of the first message.
    public var isTitleSettled: Bool = false
    /// The API message array as JSON.
    @Attribute(.allowsCloudEncryption) public var messagesJSON: String = "[]"
    public var model: String = ""
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var estimatedCost: Double = 0
    /// Suggestions whose accept/reject decision the coach has already been told about.
    public var reportedDecisionIDs: [String] = []
    /// The draft plan this conversation produced, and whether its fate has been reported.
    public var draftPlanID: UUID?
    public var draftOutcomeReported: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \PlanSuggestion.conversation)
    public var suggestions: [PlanSuggestion]? = []

    public init(kind: ConversationKind, date: Date = Date()) {
        self.kindRaw = kind.rawValue
        self.createdAt = date
        self.updatedAt = date
    }

    public var kind: ConversationKind {
        get { ConversationKind(rawValue: kindRaw) ?? .discussion }
        set { kindRaw = newValue.rawValue }
    }
}

/// One billed call to the Claude API. Kept separately from reviews and conversations so
/// the spending totals survive those being deleted.
@Model
public final class CoachCharge {
    public var uuid: UUID = UUID()
    public var date: Date = Date()
    public var kindRaw: String = CoachChargeKind.review.rawValue
    /// The review or conversation the call belonged to.
    public var sessionID: UUID = UUID()
    public var model: String = ""
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    /// Estimated cost in US dollars at list prices.
    public var cost: Double = 0
    /// Set on charges reconstructed from reviews and conversations that predate this
    /// record, so copies made on two devices can be merged.
    public var backfillKey: String?

    public init(date: Date, kind: CoachChargeKind, sessionID: UUID, model: String, inputTokens: Int, outputTokens: Int, cost: Double) {
        self.date = date
        self.kindRaw = kind.rawValue
        self.sessionID = sessionID
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
    }

    public var kind: CoachChargeKind {
        get { CoachChargeKind(rawValue: kindRaw) ?? .review }
        set { kindRaw = newValue.rawValue }
    }

    public var spendEntry: SpendEntry {
        SpendEntry(date: date, cost: cost, sessionID: sessionID)
    }
}
