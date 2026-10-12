import Analysis
import Foundation
import Models
import SwiftData

/// One thing to show in a conversation, derived from the stored history.
public enum ChatItem: Identifiable, Equatable, Sendable {
    case athlete(id: String, text: String)
    case coach(id: String, text: String)
    /// Suggestion cards produced by the tool call with this ID.
    case suggestions(id: String, toolUseID: String)
    case draftPlan(id: String)
    /// A note that the coach saved something the athlete told it.
    case saved(id: String, text: String)

    public var id: String {
        switch self {
        case .athlete(let id, _), .coach(let id, _), .suggestions(let id, _), .draftPlan(let id), .saved(let id, _): id
        }
    }
}

/// A conversation with the coach: either an interview that ends in a draft plan, or an
/// open discussion in which the coach can propose plan changes. The coach acts only
/// through the tools below, and every change to the plan still needs the athlete's Accept.
public struct CoachChat: Sendable {
    static let contextPrefix = "TRAINING DATA SNAPSHOT"
    static let updatesPrefix = "[Plan updates since your last message"

    private let client: ClaudeClient

    public init(client: ClaudeClient = ClaudeClient()) {
        self.client = client
    }

    /// Sends the athlete's message (or, with nil, picks up an exchange that failed part
    /// way) and runs until the coach has finished its reply, carrying out any tool calls
    /// on the way. Progress is saved after every step, so nothing already exchanged is lost.
    @MainActor
    public func send(
        _ text: String?,
        in conversation: CoachConversation,
        model: String,
        apiKey: String?,
        context: ModelContext,
        now: Date = Date(),
        calendar: Calendar = .current,
        onText: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.missingAPIKey
        }
        var messages = JSONValue.parse(conversation.messagesJSON)?.array ?? []

        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            var blocks: [JSONValue] = []
            if messages.isEmpty { conversation.title = String(text.prefix(80)) }
            let hasSnapshot = messages.contains { message in
                (message["content"]?.array ?? []).contains { $0["text"]?.string?.hasPrefix(Self.contextPrefix) == true }
            }
            if !hasSnapshot {
                // The coach's picture of the athlete, sent once with the first message.
                let built = try CoachPayloadBuilder.build(in: context, trigger: .onDemand, now: now, calendar: calendar)
                blocks.append(
                    .text(
                        "\(Self.contextPrefix) (as of \(built.payload.today), \(built.payload.weekday)):\n\(built.json)"
                    ))
            }
            if let updates = try pendingUpdates(for: conversation, in: context) {
                blocks.append(.text(updates))
            }
            blocks.append(.text(text))
            messages.append(.object(["role": .string("user"), "content": .array(blocks)]))
            try save(messages, to: conversation, in: context, now: now)
        }
        // Only a history ending on the athlete's side (a message or tool results) has anything to answer.
        guard messages.last?["role"]?.string == "user" else { return }

        let system = Self.systemPrompt(for: conversation.kind)
        for _ in 0..<CoachConfiguration.maxToolRounds {
            let turn = try await client.converse(
                apiKey: apiKey, model: model, system: system, messages: messages, tools: Self.tools
            ) { text in
                await onText(text)
            }
            messages.append(.object(["role": .string("assistant"), "content": .array(turn.content)]))
            conversation.model = turn.model.isEmpty ? model : turn.model
            conversation.inputTokens += turn.usage.inputTokens
            conversation.outputTokens += turn.usage.outputTokens
            conversation.estimatedCost += SpendLedger.record(
                turn.usage, kind: .conversation, sessionID: conversation.uuid, model: conversation.model,
                requestedModel: model, date: now, in: context)
            try save(messages, to: conversation, in: context, now: now)

            guard turn.stopReason == "tool_use" else { return }
            let results = turn.toolUses.map { call in
                let outcome = CoachTools.run(
                    call.name, input: call.input, toolUseID: call.id, conversation: conversation, in: context, now: now,
                    calendar: calendar)
                var block: [String: JSONValue] = [
                    "type": .string("tool_result"), "tool_use_id": .string(call.id), "content": .string(outcome.text),
                ]
                if outcome.isError { block["is_error"] = .bool(true) }
                return JSONValue.object(block)
            }
            messages.append(.object(["role": .string("user"), "content": .array(results)]))
            try save(messages, to: conversation, in: context, now: now)
            onText("")
        }
    }

    @MainActor
    private func save(_ messages: [JSONValue], to conversation: CoachConversation, in context: ModelContext, now: Date)
        throws
    {
        conversation.messagesJSON = JSONValue.array(messages).text
        conversation.updatedAt = now
        try context.save()
    }

    /// What the athlete did with the coach's proposals since it last heard, told to it
    /// once so it does not keep working from a plan that has moved on.
    @MainActor
    private func pendingUpdates(for conversation: CoachConversation, in context: ModelContext) throws -> String? {
        var lines: [String] = []
        let decided = (conversation.suggestions ?? [])
            .filter { $0.status != .pending && !conversation.reportedDecisionIDs.contains($0.uuid.uuidString) }
            .sorted { $0.createdAt < $1.createdAt }
        for suggestion in decided {
            let what = suggestion.targetSummary.isEmpty ? "new session" : suggestion.targetSummary
            lines.append("- \(suggestion.status.rawValue): \(suggestion.action.rawValue) \(what)")
            conversation.reportedDecisionIDs.append(suggestion.uuid.uuidString)
        }
        if let draftID = conversation.draftPlanID, !conversation.draftOutcomeReported {
            let plan = try context.fetch(FetchDescriptor<TrainingPlan>()).first { $0.uuid == draftID }
            if let plan, !plan.isDraft {
                lines.append("- accepted: the draft plan is now the athlete's plan")
                conversation.draftOutcomeReported = true
            } else if plan == nil {
                lines.append("- discarded: the athlete discarded the draft plan")
                conversation.draftOutcomeReported = true
            }
        }
        return lines.isEmpty ? nil : "\(Self.updatesPrefix):\n\(lines.joined(separator: "\n"))]"
    }

    /// Asks for a short name for the conversation, once it has a first exchange to name.
    /// Does nothing if a name was already suggested or typed. Only the athlete's first
    /// message and the coach's first reply are sent, not the training data.
    @MainActor
    public func suggestTitle(
        for conversation: CoachConversation, apiKey: String?, context: ModelContext, now: Date = Date()
    ) async {
        guard !conversation.isTitleSettled, let apiKey else { return }
        let items = Self.transcript(of: conversation.messagesJSON)
        let asked = items.lazy.compactMap { if case .athlete(_, let text) = $0 { text } else { nil } }.first
        let answered = items.lazy.compactMap { if case .coach(_, let text) = $0 { text } else { nil } }.first
        guard let asked, let answered else { return }

        let system = """
            Name a conversation between an athlete and their training coach. Reply with a title of three to six words that \
            says what it is about, like a subject line ("Sore knee, easier week", "Moving the long run", "Half marathon plan \
            setup"). No date, no quotation marks, no full stop.
            """
        let user = "Athlete: \(asked.prefix(600))\n\nCoach: \(answered.prefix(600))"
        guard
            let message = try? await client.send(
                apiKey: apiKey, model: CoachConfiguration.titleModel, system: system, user: user,
                format: .title, effort: CoachConfiguration.titleEffort)
        else { return }
        // The call is paid for whether or not the answer is usable.
        conversation.estimatedCost += SpendLedger.record(
            message.usage, kind: .conversation, sessionID: conversation.uuid, model: message.model,
            requestedModel: CoachConfiguration.titleModel, date: now, in: context)
        struct Reply: Decodable { var title: String }
        let title = SessionTitle.clean(
            (try? JSONDecoder().decode(Reply.self, from: Data(message.text.utf8)))?.title ?? "")
        // The user may have typed a name while this was in flight; theirs wins.
        if !title.isEmpty, !conversation.isTitleSettled {
            conversation.title = title
            conversation.isTitleSettled = true
        }
        try? context.save()
    }

    /// True when the last thing in the history is the athlete's message (or tool results)
    /// with no reply after it: a send that failed, was interrupted, or never finished.
    public static func isAwaitingReply(_ messagesJSON: String) -> Bool {
        JSONValue.parse(messagesJSON)?.array?.last?["role"]?.string == "user"
    }

    // MARK: Display

    /// The conversation as the athlete should see it: their words, the coach's words,
    /// and a marker wherever the coach proposed or saved something.
    public static func transcript(of messagesJSON: String) -> [ChatItem] {
        var items: [ChatItem] = []
        for (m, message) in (JSONValue.parse(messagesJSON)?.array ?? []).enumerated() {
            let isCoach = message["role"]?.string == "assistant"
            for (b, block) in (message["content"]?.array ?? []).enumerated() {
                let id = "m\(m)b\(b)"
                switch block["type"]?.string {
                case "text":
                    guard let text = block["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    else { continue }
                    if isCoach {
                        items.append(.coach(id: id, text: text))
                    } else if !text.hasPrefix(contextPrefix), !text.hasPrefix(updatesPrefix) {
                        items.append(.athlete(id: id, text: text))
                    }
                case "tool_use":
                    guard let toolID = block["id"]?.string else { continue }
                    switch block["name"]?.string {
                    case CoachTools.proposeChanges: items.append(.suggestions(id: id, toolUseID: toolID))
                    case CoachTools.proposePlan: items.append(.draftPlan(id: id))
                    case CoachTools.saveAthleteDetails:
                        items.append(.saved(id: id, text: "Saved your availability and notes"))
                    case CoachTools.saveGoal: items.append(.saved(id: id, text: "Saved your goal"))
                    default: break
                    }
                default:
                    break
                }
            }
        }
        return items
    }

    // MARK: Prompt and tools

    static func systemPrompt(for kind: ConversationKind) -> String {
        let mode =
            switch kind {
            case .interview:
                """
                The athlete has no training plan and wants one. Interview them, then write it.
                - Open by saying in a sentence or two what you can already see in their data, then ask your first question.
                - Ask one or two questions at a time and wait for the answer. Never ask for anything the snapshot already tells you.
                - Find out what you need and no more: which goal and what they want from it (a target time, or just to finish); \
                which days and how long they can train; which sports they want in the week; injuries, niggles or constraints; \
                anything they love or hate doing. Four to seven exchanges is usually enough.
                - As you learn them, record lasting facts with save_athlete_details (availability, sports, notes) and save_goal.
                - When you have enough, say briefly how you will shape the plan, then call propose_plan with the whole plan. \
                Afterwards tell them a draft is ready to review and that nothing changes until they accept it.
                """
            case .discussion:
                """
                The athlete wants to talk about their training. Answer what they ask, using their data. If they tell you \
                something that should change the plan (a missed week, a sore knee, a trip, feeling flat, wanting more or less), \
                work out what should change and propose it.
                - Use propose_changes for adjustments to particular sessions. Use propose_plan only when the plan needs \
                rewriting from a date onward, and say that is what you are doing.
                - If time has passed or changes have been accepted since the snapshot, call get_plan_sessions before proposing, \
                so you are working from the plan as it is now.
                - Record lasting facts they mention with save_athlete_details or save_goal.
                """
            }
        return """
            You are a training coach talking with one amateur endurance athlete. You are a training assistant, not a medical \
            service. If they describe pain, injury, illness or worrying symptoms, or the data shows abnormal readings, say so \
            plainly and recommend seeing a doctor or physiotherapist rather than training through it. Never diagnose.

            The first message carries a JSON snapshot of the athlete: profile, goals, plan (recent and upcoming sessions, each \
            with an id), completed workouts and how they matched the plan, daily recovery metrics with the athlete's own \
            baselines, and training-load trends. Durations are minutes, distances kilometres, heart rate beats per minute, \
            power watts. "load" is minutes weighted by heart-rate zone (1 to 5 points per minute). "loadRatio" is the last \
            7 days' average daily load over the last 28 days'; roughly 0.8 to 1.3 is steady.

            \(mode)

            How to talk: like a coach in a chat, not a report. Plain text only, no markdown, no headings or bullet symbols. \
            Keep replies short, usually a few sentences. Be direct and specific to their numbers.

            How changes work: you cannot change the plan yourself. propose_changes and propose_plan show the athlete \
            proposals, which they accept or reject one by one. So say "I've suggested", never "I've changed". A message \
            beginning "\(updatesPrefix)" tells you what they decided; take it as fact.

            Rules for proposals: only sessions dated today or later. For modify, move and remove give the session's id; for \
            add give null. Set only the fields that change and leave the rest null. Respect the athlete's availability \
            (schedule nothing on a day with zero hours) and their notes. Do not put hard sessions (tempo, intervals, race, \
            long) on consecutive days, and keep week-to-week changes gradual. When writing a whole plan: start from recent \
            training, build about ten percent a week with a lighter week every third or fourth, cover the dates with phases \
            without gaps, taper before the goal event, put a session of type race on the goal date, and leave rest days empty. \
            Dates are YYYY-MM-DD.
            """
    }

    /// The same tools in every conversation, so the cached prefix is shared.
    static let tools: [JSONValue] = {
        func nullable(_ type: String) -> [String: Any] { ["anyOf": [["type": type], ["type": "null"]]] }
        // The API allows only 16 nullable parameters across all strict schemas, so strict
        // is kept for the two tools that write proposals; the others are validated here.
        func tool(
            _ name: String, _ description: String, strict: Bool = false, properties: [String: Any], required: [String]
        ) -> JSONValue {
            JSONValue(
                any: [
                    "name": name,
                    "description": description,
                    "strict": strict,
                    "input_schema": [
                        "type": "object", "additionalProperties": false, "required": required, "properties": properties,
                    ] as [String: Any],
                ] as [String: Any])
        }
        let review = CoachResponse.schema["properties"] as? [String: Any] ?? [:]
        let plan = PlanResponse.schema["properties"] as? [String: Any] ?? [:]
        return [
            tool(
                CoachTools.getPlanSessions,
                "Read the athlete's planned sessions as they are right now, between two dates inclusive. Use it before proposing changes if the plan may have changed since the snapshot.",
                properties: [
                    "from": ["type": "string", "description": "YYYY-MM-DD"],
                    "to": ["type": "string", "description": "YYYY-MM-DD"],
                ],
                required: ["from", "to"]),
            tool(
                CoachTools.proposeChanges,
                "Show the athlete specific changes to upcoming sessions. Each appears as a before/after card they accept or reject. Nothing changes until they accept.",
                strict: true,
                properties: ["suggestions": review["suggestions"] ?? [:]],
                required: ["suggestions"]),
            tool(
                CoachTools.proposePlan,
                "Give the athlete a complete plan for a date range as a draft to review. If they accept it, it replaces whatever they had planned from its start date on.",
                strict: true,
                properties: [
                    "start": ["type": "string", "description": "First day of the plan, YYYY-MM-DD"],
                    "end": ["type": "string", "description": "Last day of the plan, YYYY-MM-DD"],
                    "goalTitle": nullable("string"),
                    "summary": plan["summary"] ?? [:],
                    "phases": plan["phases"] ?? [:],
                    "sessions": plan["sessions"] ?? [:],
                ],
                required: ["start", "end", "goalTitle", "summary", "phases", "sessions"]),
            tool(
                CoachTools.saveAthleteDetails,
                "Record lasting facts the athlete has told you so future reviews see them. Pass null for anything not discussed. Notes replace the existing notes, so include what should be kept.",
                properties: [
                    "availabilityHoursMonToSun": [
                        "anyOf": [["type": "array", "items": ["type": "number"]], ["type": "null"]],
                        "description": "Seven numbers, Monday first; 0 for a day off",
                    ],
                    "sports": [
                        "anyOf": [
                            [
                                "type": "array",
                                "items": ["type": "string", "enum": ["swim", "bike", "run", "strength"]],
                            ], ["type": "null"],
                        ]
                    ],
                    "notes": nullable("string"),
                ],
                required: ["availabilityHoursMonToSun", "sports", "notes"]),
            tool(
                CoachTools.saveGoal,
                "Create a goal, or update the one with the same title.",
                properties: [
                    "title": ["type": "string"],
                    "sport": [
                        "anyOf": [["type": "string", "enum": Sport.allCases.map(\.rawValue)], ["type": "null"]]
                    ],
                    "distanceKm": nullable("number"),
                    "date": nullable("string"),
                    "target": [
                        "anyOf": [["type": "string"], ["type": "null"]], "description": "For example a finish time",
                    ],
                    "priority": ["type": "string", "enum": GoalPriority.allCases.map(\.rawValue)],
                ],
                required: ["title", "sport", "distanceKm", "date", "target", "priority"]),
        ]
    }()
}

/// What the coach can do in a conversation. Reading is free; anything that would change
/// the plan becomes a proposal for the athlete instead.
enum CoachTools {
    static let getPlanSessions = "get_plan_sessions"
    static let proposeChanges = "propose_changes"
    static let proposePlan = "propose_plan"
    static let saveAthleteDetails = "save_athlete_details"
    static let saveGoal = "save_goal"

    struct Outcome {
        var text: String
        var isError = false
    }

    @MainActor
    static func run(
        _ name: String, input: JSONValue, toolUseID: String, conversation: CoachConversation, in context: ModelContext,
        now: Date, calendar: Calendar
    ) -> Outcome {
        do {
            switch name {
            case getPlanSessions: return try planSessions(input, in: context, calendar: calendar)
            case proposeChanges:
                return try propose(
                    input, toolUseID: toolUseID, conversation: conversation, in: context, now: now, calendar: calendar)
            case proposePlan:
                return try proposePlan(input, conversation: conversation, in: context, now: now, calendar: calendar)
            case saveAthleteDetails: return try saveDetails(input, in: context)
            case saveGoal: return try saveGoal(input, in: context, calendar: calendar)
            default: return Outcome(text: "Unknown tool \(name).", isError: true)
            }
        } catch let error as ToolError {
            return Outcome(text: error.message, isError: true)
        } catch {
            return Outcome(
                text: "The input could not be read. Check it against the tool's schema and try again.", isError: true)
        }
    }

    struct ToolError: Error {
        let message: String
    }

    private static func sessions(in context: ModelContext) throws -> [PlannedWorkout] {
        try context.fetch(FetchDescriptor<PlannedWorkout>()).filter { $0.plan?.isDraft != true }
    }

    static func shortID(_ session: PlannedWorkout) -> String {
        String(session.uuid.uuidString.prefix(8)).lowercased()
    }

    @MainActor
    private static func planSessions(_ input: JSONValue, in context: ModelContext, calendar: Calendar) throws -> Outcome
    {
        guard let from = SuggestionApplier.date(from: input["from"]?.string, calendar: calendar),
            let to = SuggestionApplier.date(from: input["to"]?.string, calendar: calendar), from <= to
        else {
            throw ToolError(message: "Give from and to as YYYY-MM-DD, with from on or before to.")
        }
        let style = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        let found = try sessions(in: context)
            .filter { calendar.startOfDay(for: $0.date) >= from && calendar.startOfDay(for: $0.date) <= to }
            .sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
            .map { session in
                CoachPayload.Session(
                    id: shortID(session),
                    date: session.date.formatted(style),
                    sport: session.sport.rawValue,
                    type: session.sessionType.rawValue,
                    minutes: session.targetDurationSeconds.map { ($0 / 60).rounded() },
                    km: session.targetDistanceMeters.map { ($0 / 100).rounded() / 10 },
                    intensity: session.targetIntensity.isEmpty ? nil : session.targetIntensity,
                    instructions: session.instructions.isEmpty ? nil : session.instructions,
                    status: session.status.rawValue,
                    percentOfTarget: session.complianceRatio.map { Int(($0 * 100).rounded()) }
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Outcome(text: String(decoding: try encoder.encode(found), as: UTF8.self))
    }

    @MainActor
    private static func propose(
        _ input: JSONValue, toolUseID: String, conversation: CoachConversation, in context: ModelContext, now: Date,
        calendar: Calendar
    ) throws -> Outcome {
        guard let value = input["suggestions"] else { throw ToolError(message: "suggestions is required.") }
        let proposals = try value.decode([CoachSuggestion].self)
        let all = try sessions(in: context)
        let today = calendar.startOfDay(for: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var shown = 0
        var problems: [String] = []
        for (index, proposal) in proposals.enumerated() {
            var target: PlannedWorkout?
            if proposal.action != .add {
                let id = proposal.sessionId?.lowercased() ?? ""
                target = id.isEmpty ? nil : all.first { $0.uuid.uuidString.lowercased().hasPrefix(id) }
                guard let target else {
                    problems.append("no session with id \(proposal.sessionId ?? "null")")
                    continue
                }
                if calendar.startOfDay(for: target.date) < today {
                    problems.append("session \(shortID(target)) is in the past")
                    continue
                }
            }
            if let date = SuggestionApplier.date(from: proposal.date, calendar: calendar), date < today {
                problems.append("\(proposal.date ?? "") is in the past")
                continue
            }
            if proposal.action == .add,
                SuggestionApplier.date(from: proposal.date, calendar: calendar) == nil || proposal.sport == nil
            {
                problems.append("an added session needs a date and a sport")
                continue
            }
            let record = PlanSuggestion(
                action: proposal.action,
                proposedChangeJSON: String(decoding: try encoder.encode(proposal), as: UTF8.self),
                rationale: proposal.rationale
            )
            record.createdAt = now.addingTimeInterval(Double(index) / 1000)
            record.sourceID = toolUseID
            context.insert(record)
            record.conversation = conversation
            record.targetWorkout = target
            record.targetSummary = target.map { SuggestionApplier.summary(of: $0, calendar: calendar) } ?? ""
            shown += 1
        }
        var text =
            "\(shown) suggestion\(shown == 1 ? "" : "s") shown to the athlete to accept or reject. Nothing has changed yet."
        if !problems.isEmpty { text += " Not shown: \(problems.joined(separator: "; "))." }
        return Outcome(text: text, isError: shown == 0 && !problems.isEmpty)
    }

    private struct PlanInput: Decodable {
        var start: String
        var end: String
        var goalTitle: String?
        var summary: String
        var phases: [PlanResponse.Phase]
        var sessions: [PlanResponse.Session]
    }

    @MainActor
    private static func proposePlan(
        _ input: JSONValue, conversation: CoachConversation, in context: ModelContext, now: Date, calendar: Calendar
    ) throws -> Outcome {
        let plan = try input.decode(PlanInput.self)
        guard let start = SuggestionApplier.date(from: plan.start, calendar: calendar),
            let end = SuggestionApplier.date(from: plan.end, calendar: calendar), start <= end
        else {
            throw ToolError(message: "Give start and end as YYYY-MM-DD, with start on or before end.")
        }
        guard start >= calendar.startOfDay(for: now) else {
            throw ToolError(message: "The plan must start today or later.")
        }

        let goals = try context.fetch(FetchDescriptor<Goal>()).filter { $0.status == .active }
        let goal =
            goals.first { $0.title.caseInsensitiveCompare(plan.goalTitle ?? "") == .orderedSame }
            ?? goals.filter { ($0.targetDate ?? .distantPast) >= start }.min {
                ($0.priority, $0.targetDate ?? .distantFuture) < ($1.priority, $1.targetDate ?? .distantFuture)
            }
        let response = PlanResponse(summary: plan.summary, phases: plan.phases, sessions: plan.sessions)
        let draft: TrainingPlan
        do {
            draft = try CoachPlanner.makeDraft(
                response, start: start, end: end, goal: goal, in: context, now: now, calendar: calendar)
        } catch {
            throw ToolError(
                message: "None of the sessions fall between start and end. Check the dates and send the plan again.")
        }
        conversation.draftPlanID = draft.uuid
        conversation.draftOutcomeReported = false
        let dropped = plan.sessions.count - (draft.workouts?.count ?? 0)
        var text =
            "Draft plan with \(draft.workouts?.count ?? 0) sessions from \(plan.start) to \(plan.end) is ready for the athlete to review. Nothing changes until they accept it."
        if dropped > 0 { text += " \(dropped) session\(dropped == 1 ? "" : "s") outside those dates were left out." }
        return Outcome(text: text)
    }

    private struct DetailsInput: Decodable {
        var availabilityHoursMonToSun: [Double]?
        var sports: [Sport]?
        var notes: String?
    }

    @MainActor
    private static func saveDetails(_ input: JSONValue, in context: ModelContext) throws -> Outcome {
        let details = try input.decode(DetailsInput.self)
        if let hours = details.availabilityHoursMonToSun,
            hours.count != 7 || hours.contains(where: { $0 < 0 || $0 > 24 })
        {
            throw ToolError(message: "availabilityHoursMonToSun must be seven numbers between 0 and 24, Monday first.")
        }
        var descriptor = FetchDescriptor<AthleteProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        let profile: AthleteProfile
        if let existing = try context.fetch(descriptor).first {
            profile = existing
        } else {
            profile = AthleteProfile()
            context.insert(profile)
        }
        if let hours = details.availabilityHoursMonToSun { profile.availabilityHours = hours }
        if let sports = details.sports, !sports.isEmpty { profile.enabledSports = sports }
        if let notes = details.notes { profile.coachNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Outcome(text: "Saved.")
    }

    private struct GoalInput: Decodable {
        var title: String
        var sport: Sport?
        var distanceKm: Double?
        var date: String?
        var target: String?
        var priority: GoalPriority
    }

    @MainActor
    private static func saveGoal(_ input: JSONValue, in context: ModelContext, calendar: Calendar) throws -> Outcome {
        let details = try input.decode(GoalInput.self)
        let title = details.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ToolError(message: "The goal needs a title.") }
        let existing = try context.fetch(FetchDescriptor<Goal>()).first {
            $0.title.caseInsensitiveCompare(title) == .orderedSame
        }
        let goal = existing ?? Goal(title: title)
        if existing == nil { context.insert(goal) }
        goal.priority = details.priority
        // Null means "not discussed", so what is already known is kept.
        if let sport = details.sport { goal.eventSport = sport }
        if let km = details.distanceKm, km > 0 { goal.eventDistanceMeters = km * 1000 }
        if let date = SuggestionApplier.date(from: details.date, calendar: calendar) { goal.targetDate = date }
        if let target = details.target { goal.targetMetric = target }
        return Outcome(text: existing == nil ? "Goal created." : "Goal updated.")
    }
}

public enum SessionTitle {
    /// Tidies a name from the model or the user: one line, no wrapping quotes or trailing
    /// full stop, and not too long.
    public static func clean(_ raw: String) -> String {
        var title = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let quotes = CharacterSet(charactersIn: "\"'“”‘’")
        title = title.trimmingCharacters(in: quotes)
        if title.hasSuffix("."), !title.hasSuffix("..") { title.removeLast() }
        title = title.trimmingCharacters(in: quotes)
        if title.count > CoachConfiguration.titleMaxCharacters {
            title =
                String(title.prefix(CoachConfiguration.titleMaxCharacters)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    @MainActor
    public static func rename(_ conversation: CoachConversation, to raw: String) {
        let title = clean(raw)
        guard !title.isEmpty else { return }
        conversation.title = title
        conversation.isTitleSettled = true
    }

    @MainActor
    public static func rename(_ review: CoachReview, to raw: String) {
        // An empty name puts the review back to being listed by its date.
        review.title = clean(raw)
    }
}
