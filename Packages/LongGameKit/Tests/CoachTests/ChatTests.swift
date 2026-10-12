import Analysis
import Foundation
import Models
import SwiftData
import Testing

@testable import Coach

/// Builds the server-sent events for one assistant turn made of the given blocks.
enum Turn {
    case thinking(signature: String)
    case text([String])
    case tool(id: String, name: String, inputChunks: [String])

    static func events(_ blocks: [Turn], stop: String, input: Int = 9000, cacheRead: Int = 0, output: Int = 200)
        -> [String]
    {
        func data(_ object: [String: Any]) -> String {
            "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        var lines = [
            data([
                "type": "message_start",
                "message": [
                    "model": "claude-opus-5-5",
                    "usage": [
                        "input_tokens": input, "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": 0,
                        "output_tokens": 1,
                    ],
                ],
            ])
        ]
        for (index, block) in blocks.enumerated() {
            switch block {
            case .thinking(let signature):
                lines.append(
                    data([
                        "type": "content_block_start", "index": index,
                        "content_block": ["type": "thinking", "thinking": "", "signature": ""],
                    ]))
                // Signatures arrive in pieces and must be reassembled exactly.
                let half = signature.index(signature.startIndex, offsetBy: signature.count / 2)
                for piece in [String(signature[..<half]), String(signature[half...])] {
                    lines.append(
                        data([
                            "type": "content_block_delta", "index": index,
                            "delta": ["type": "signature_delta", "signature": piece],
                        ]))
                }
            case .text(let chunks):
                lines.append(
                    data([
                        "type": "content_block_start", "index": index, "content_block": ["type": "text", "text": ""],
                    ]))
                lines += chunks.map {
                    data(["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": $0]])
                }
            case .tool(let id, let name, let chunks):
                lines.append(
                    data([
                        "type": "content_block_start", "index": index,
                        "content_block": ["type": "tool_use", "id": id, "name": name, "input": [String: Any]()],
                    ]))
                lines += chunks.map {
                    data([
                        "type": "content_block_delta", "index": index,
                        "delta": ["type": "input_json_delta", "partial_json": $0],
                    ])
                }
            }
            lines.append(data(["type": "content_block_stop", "index": index]))
        }
        lines.append(
            data(["type": "message_delta", "delta": ["stop_reason": stop], "usage": ["output_tokens": output]]))
        lines.append(data(["type": "message_stop"]))
        return lines
    }
}

@Suite struct ConversationClientTests {
    @Test func rebuildsEveryBlockOfATurn() async throws {
        let transport = MockTransport([
            .response(
                status: 200,
                lines: Turn.events(
                    [
                        .thinking(signature: "c2lnbmF0dXJlLWJ5dGVz"),
                        .text(["Let me ", "look."]),
                        .tool(
                            id: "toolu_1", name: "get_plan_sessions",
                            inputChunks: ["{\"from\":\"2026-", "10-12\",\"to\":\"2026-10-18\"}"]),
                        .tool(id: "toolu_2", name: "noop", inputChunks: []),
                    ], stop: "tool_use", input: 9000, cacheRead: 8000))
        ])
        let seen = Collector()
        let turn = try await ClaudeClient(transport: transport, retryDelays: []).converse(
            apiKey: "k", model: "claude-opus-5-5", system: "sys",
            messages: [.object(["role": .string("user"), "content": .string("hi")])], tools: CoachChat.tools
        ) { await seen.add($0) }

        #expect(turn.stopReason == "tool_use")
        #expect(turn.content.count == 4)
        #expect(
            turn.content[0]
                == .object([
                    "type": .string("thinking"), "thinking": .string(""), "signature": .string("c2lnbmF0dXJlLWJ5dGVz"),
                ]))
        #expect(turn.text == "Let me look.")
        #expect(turn.toolUses.map(\.name) == ["get_plan_sessions", "noop"])
        #expect(turn.toolUses[0].input == .object(["from": .string("2026-10-12"), "to": .string("2026-10-18")]))
        #expect(turn.toolUses[1].input == .object([:]))
        #expect(await seen.values == ["Let me ", "Let me look."])
        // 9000 fresh + 8000 from the cache.
        #expect(
            turn.usage
                == ClaudeUsage(inputTokens: 17_000, outputTokens: 200, cacheReadTokens: 8000, cacheWriteTokens: 0))
    }

    @Test func conversationRequestsCarryToolsAndCaching() throws {
        let request = try ClaudeClient.conversationRequest(
            apiKey: "k", model: "claude-opus-5-5", system: "sys", messages: [], tools: CoachChat.tools)
        let body = try jsonBody(request)
        #expect(
            (body["tools"] as? [[String: Any]])?.map { $0["name"] as? String } == [
                "get_plan_sessions", "propose_changes", "propose_plan", "save_athlete_details", "save_goal",
            ])
        // Only the tools that write proposals are strict: the API caps nullable parameters across strict schemas at 16.
        let strict = (body["tools"] as? [[String: Any]])?.filter { $0["strict"] as? Bool == true } ?? []
        #expect(strict.map { $0["name"] as? String } == ["propose_changes", "propose_plan"])
        let unions =
            String(decoding: try JSONSerialization.data(withJSONObject: strict), as: UTF8.self).components(
                separatedBy: "\"anyOf\""
            ).count - 1
        #expect(unions <= 16)
        #expect((body["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        // Rejected by the current models, so never sent.
        #expect(body["tool_choice"] == nil)
        #expect(body["thinking"] == nil)
    }

    @Test func cachedInputIsCheaper() {
        let usage = ClaudeUsage(inputTokens: 10_000, outputTokens: 1000, cacheReadTokens: 8000, cacheWriteTokens: 1000)
        // 1000 plain + 8000 × 0.05 + 1000 × 1.25 = 2650 input-equivalent tokens.
        let cost = CoachConfiguration.cost(model: "claude-opus-5-5", usage: usage) ?? 0
        #expect(abs(cost - (2650 * 4 + 1000 * 20) / 1_000_000) < 1e-9)
    }

    @Test func jsonValuesSurviveARoundTrip() {
        let text = #"{"a":[1,2.5,true,null,"x"],"b":{"c":"d"}}"#
        #expect(JSONValue.parse(text)?.text == text)
    }
}

@MainActor
@Suite struct CoachChatTests {
    let container: ModelContainer
    let context: ModelContext
    let calendar = Calendar.current
    let now: Date
    let plan: TrainingPlan

    init() throws {
        container = try LongGameStore.makeContainer(mode: .inMemory)
        context = container.mainContext
        now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)).addingTimeInterval(9 * 3600)
        context.insert(AthleteProfile())
        context.insert(
            Goal(
                title: "Half Marathon", eventSport: .run, targetDate: calendar.date(byAdding: .day, value: 60, to: now))
        )
        plan = TrainingPlan(
            name: "Plan", startDate: calendar.date(byAdding: .day, value: -10, to: now)!,
            endDate: calendar.date(byAdding: .day, value: 60, to: now)!)
        context.insert(plan)
    }

    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }
    func text(_ offset: Int) -> String {
        day(offset).formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
    }

    @discardableResult
    func session(day offset: Int, _ sport: Sport = .run, type: SessionType = .tempo) -> PlannedWorkout {
        let session = PlannedWorkout(date: day(offset), sport: sport, sessionType: type, targetDurationSeconds: 3600)
        context.insert(session)
        session.plan = plan
        return session
    }

    func chat(_ steps: [[String]]) -> (CoachChat, MockTransport) {
        let transport = MockTransport(steps.map { .response(status: 200, lines: $0) })
        return (CoachChat(client: ClaudeClient(transport: transport, retryDelays: [])), transport)
    }

    func messages(_ request: URLRequest?) throws -> [JSONValue] {
        let body = try #require(request?.httpBody)
        return try #require(JSONValue.parse(String(decoding: body, as: UTF8.self))?["messages"]?.array)
    }

    @Test func aDiscussionProposesChangesAndHearsWhatWasDecided() async throws {
        let target = session(day: 2)
        let past = session(day: -2)
        let id = CoachTools.shortID(target)
        let suggestions = """
            {"suggestions":[\
            {"action":"modify","sessionId":"\(id)","date":null,"sport":null,"sessionType":"easy","durationMinutes":40,"distanceKm":null,"intensity":"Z2","instructions":null,"rationale":"Ease off while the knee settles."},\
            {"action":"remove","sessionId":"\(CoachTools.shortID(past))","date":null,"sport":null,"sessionType":null,"durationMinutes":null,"distanceKm":null,"intensity":null,"instructions":null,"rationale":"Already gone."},\
            {"action":"move","sessionId":"zzzzzzzz","date":"\(text(4))","sport":null,"sessionType":null,"durationMinutes":null,"distanceKm":null,"intensity":null,"instructions":null,"rationale":"?"}]}
            """
        let (chat, transport) = chat([
            Turn.events(
                [
                    .thinking(signature: "c2ln"), .text(["Sorry about the knee."]),
                    .tool(
                        id: "toolu_a", name: "propose_changes",
                        inputChunks: [String(suggestions.prefix(60)), String(suggestions.dropFirst(60))]),
                ], stop: "tool_use"),
            Turn.events([.text(["I've suggested easing Wednesday."])], stop: "end_turn", cacheRead: 8500),
            Turn.events([.text(["Good call."])], stop: "end_turn"),
        ])
        let conversation = CoachConversation(kind: .discussion, date: now)
        context.insert(conversation)

        try await chat.send(
            "My knee is sore after Sunday.", in: conversation, model: "claude-opus-5-5", apiKey: "k", context: context,
            now: now, calendar: calendar)

        // The first request opens with the data snapshot, then the athlete's words.
        let first = try messages(transport.requests[0])
        #expect(first.count == 1)
        let opening = try #require(first[0]["content"]?.array)
        #expect(opening.count == 2)
        #expect(opening[0]["text"]?.string?.hasPrefix("TRAINING DATA SNAPSHOT") == true)
        #expect(opening[0]["text"]?.string?.contains("\"today\":\"\(text(0))\"") == true)
        #expect(opening[1]["text"]?.string == "My knee is sore after Sunday.")

        // The second request replays the coach's turn untouched, signature and all, then the tool result.
        let second = try messages(transport.requests[1])
        #expect(second.count == 3)
        #expect(second[0] == first[0])
        #expect(
            second[1]["content"]?.array?.first
                == .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("c2ln")]))
        let result = try #require(second[2]["content"]?.array?.first)
        #expect(result["type"]?.string == "tool_result")
        #expect(result["tool_use_id"]?.string == "toolu_a")
        #expect(result["content"]?.string?.hasPrefix("1 suggestion shown") == true)
        #expect(result["content"]?.string?.contains("is in the past") == true)
        #expect(result["content"]?.string?.contains("no session with id zzzzzzzz") == true)

        // One card, pending; the plan itself has not moved.
        let cards = conversation.suggestions ?? []
        #expect(cards.count == 1)
        #expect(cards.first?.sourceID == "toolu_a")
        #expect(cards.first?.targetWorkout === target)
        #expect(target.sessionType == .tempo)
        #expect(conversation.title == "My knee is sore after Sunday.")
        #expect(conversation.inputTokens == 9000 + 9000 + 8500)
        #expect(conversation.estimatedCost > 0)
        // Each API call is in the ledger, under this conversation.
        let charges = try context.fetch(FetchDescriptor<CoachCharge>())
        #expect(charges.count == 2)
        #expect(charges.allSatisfy { $0.sessionID == conversation.uuid && $0.kind == .conversation })
        #expect(abs(charges.reduce(0) { $0 + $1.cost } - conversation.estimatedCost) < 1e-9)

        #expect(
            CoachChat.transcript(of: conversation.messagesJSON) == [
                .athlete(id: "m0b1", text: "My knee is sore after Sunday."),
                .coach(id: "m1b1", text: "Sorry about the knee."),
                .suggestions(id: "m1b2", toolUseID: "toolu_a"),
                .coach(id: "m3b0", text: "I've suggested easing Wednesday."),
            ])

        // The athlete accepts; the coach is told once, with the next message.
        try SuggestionApplier.accept(try #require(cards.first), in: context, calendar: calendar)
        #expect(target.sessionType == .easy)
        try await chat.send(
            "Thanks, done.", in: conversation, model: "claude-opus-5-5", apiKey: "k", context: context, now: now,
            calendar: calendar)

        let third = try messages(transport.requests[2])
        // History only ever grows: everything sent before is sent again, byte for byte.
        #expect(Array(third.prefix(3)) == second)
        let followUp = try #require(third[4]["content"]?.array)
        #expect(followUp[0]["text"]?.string?.hasPrefix("[Plan updates since your last message") == true)
        #expect(followUp[0]["text"]?.string?.contains("accepted: modify") == true)
        #expect(followUp[1]["text"]?.string == "Thanks, done.")
        #expect(conversation.reportedDecisionIDs.count == 1)
        #expect(CoachChat.transcript(of: conversation.messagesJSON).last == .coach(id: "m5b0", text: "Good call."))
    }

    @Test func anInterviewSavesWhatItLearnsAndDraftsAPlan() async throws {
        try PlanReconciler.discardDraft(plan, in: context)
        context.delete(plan)
        try context.save()
        let details =
            #"{"availabilityHoursMonToSun":[1,1,0,1,1,2,3],"sports":["run","bike","strength"],"notes":"Left knee: avoid long descents."}"#
        let goal =
            #"{"title":"half marathon","sport":"run","distanceKm":21.1,"date":null,"target":"Under 1:50","priority":"A"}"#
        let planInput = """
            {"start":"\(text(1))","end":"\(text(28))","goalTitle":"Half Marathon","summary":"Four weeks to rebuild.","phases":[{"kind":"base","start":"\(text(1))","end":"\(text(28))"}],\
            "sessions":[{"date":"\(text(1))","sport":"run","sessionType":"easy","durationMinutes":40,"distanceKm":null,"intensity":"Z2","instructions":null},\
            {"date":"\(text(3))","sport":"bike","sessionType":"long","durationMinutes":90,"distanceKm":null,"intensity":"Z2","instructions":null},\
            {"date":"\(text(90))","sport":"run","sessionType":"easy","durationMinutes":40,"distanceKm":null,"intensity":null,"instructions":null}]}
            """
        let (chat, transport) = chat([
            Turn.events([.text(["I can see four steady weeks. Which days can you train?"])], stop: "end_turn"),
            Turn.events(
                [
                    .tool(id: "toolu_d", name: "save_athlete_details", inputChunks: [details]),
                    .tool(id: "toolu_g", name: "save_goal", inputChunks: [goal]),
                ], stop: "tool_use"),
            Turn.events(
                [
                    .text(["Here's how I'll shape it."]),
                    .tool(id: "toolu_p", name: "propose_plan", inputChunks: [planInput]),
                ], stop: "tool_use"),
            Turn.events([.text(["Your draft is ready to review."])], stop: "end_turn"),
        ])
        let conversation = CoachConversation(kind: .interview, date: now)
        context.insert(conversation)

        try await chat.send(
            "I'd like to set up a training plan.", in: conversation, model: "claude-opus-5-5", apiKey: "k",
            context: context, now: now, calendar: calendar)
        try await chat.send(
            "Not Wednesdays. Knee hates descents. I want under 1:50.", in: conversation, model: "claude-opus-5-5",
            apiKey: "k", context: context, now: now, calendar: calendar)

        // The interview prompt was used.
        let body = try jsonBody(transport.requests[0])
        #expect((body["system"] as? String)?.contains("Interview them") == true)

        let profile = try #require(try context.fetch(FetchDescriptor<AthleteProfile>()).first)
        #expect(profile.availabilityHours == [1, 1, 0, 1, 1, 2, 3])
        #expect(profile.enabledSports == [.run, .bike, .strength])
        #expect(profile.coachNotes == "Left knee: avoid long descents.")
        // The existing goal is updated, not duplicated, and its date is kept.
        let goals = try context.fetch(FetchDescriptor<Goal>())
        #expect(goals.count == 1)
        #expect(goals.first?.targetMetric == "Under 1:50")
        #expect(goals.first?.targetDay != nil)

        let draft = try #require(try context.fetch(FetchDescriptor<TrainingPlan>()).first)
        #expect(draft.isDraft)
        #expect(draft.goal === goals.first)
        #expect(draft.workouts?.count == 2)
        #expect(conversation.draftPlanID == draft.uuid)

        // Both tool calls in one turn are answered together, in one message.
        let afterTools = try messages(transport.requests[2])
        let results = try #require(afterTools.last?["content"]?.array)
        #expect(results.map { $0["tool_use_id"]?.string } == ["toolu_d", "toolu_g"])
        #expect(results.map { $0["content"]?.string } == ["Saved.", "Goal updated."])
        let planResult = try #require(
            try messages(transport.requests[3]).last?["content"]?.array?.first?["content"]?.string)
        #expect(planResult.contains("2 sessions"))
        #expect(planResult.contains("1 session outside those dates"))

        #expect(
            CoachChat.transcript(of: conversation.messagesJSON).map(\.id) == [
                "m0b1", "m1b0", "m2b0", "m3b0", "m3b1", "m5b0", "m5b1", "m7b0",
            ])
        #expect(CoachChat.transcript(of: conversation.messagesJSON)[6] == .draftPlan(id: "m5b1"))
    }

    @Test func conversationsAreNamedOnceAndAUsersNameWins() async throws {
        func titleReply(_ title: String) -> [String] {
            MockTransport.events(chunks: ["{\"title\":\"\(title)\"}"], model: "claude-haiku-5-5")
        }
        let (chat, transport) = chat([
            Turn.events([.text(["Let's ease the week."])], stop: "end_turn"),
            titleReply("Sore knee, easier week."),
            titleReply("Something else"),
        ])
        let conversation = CoachConversation(kind: .discussion, date: now)
        context.insert(conversation)

        // Nothing to name before there is an exchange.
        await chat.suggestTitle(for: conversation, apiKey: "k", context: context, now: now)
        #expect(transport.requests.isEmpty)

        try await chat.send(
            "My knee is sore after Sunday's long run and I am worried about the week.", in: conversation,
            model: "claude-opus-5-5", apiKey: "k", context: context, now: now, calendar: calendar)
        #expect(conversation.title.hasPrefix("My knee is sore"))
        #expect(!conversation.isTitleSettled)

        await chat.suggestTitle(for: conversation, apiKey: "k", context: context, now: now)
        #expect(conversation.title == "Sore knee, easier week")
        #expect(conversation.isTitleSettled)

        // The naming request goes to the small model and carries the two messages, not the training data.
        let body = try jsonBody(transport.requests[1])
        #expect(body["model"] as? String == "claude-haiku-5-5")
        let sent = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(sent.contains("My knee is sore"))
        #expect(sent.contains("Let's ease the week."))
        #expect(!sent.contains("TRAINING DATA SNAPSHOT"))
        // It is charged to the same session.
        #expect(
            try context.fetch(FetchDescriptor<CoachCharge>()).filter { $0.sessionID == conversation.uuid }.count == 2)

        // Once named, it is not asked again; and a name the user types sticks.
        await chat.suggestTitle(for: conversation, apiKey: "k", context: context, now: now)
        #expect(transport.requests.count == 2)
        SessionTitle.rename(conversation, to: "Knee week")
        #expect(conversation.title == "Knee week")
        SessionTitle.rename(conversation, to: "   ")
        #expect(conversation.title == "Knee week")
        #expect(SessionTitle.clean(String(repeating: "long ", count: 30)).count <= 61)
    }

    @Test func aFailedTurnCanBePickedUpWithoutResending() async throws {
        let transport = MockTransport([
            .response(status: 401, lines: [#"{"error":{"type":"authentication_error","message":"bad key"}}"#]),
            .response(status: 200, lines: Turn.events([.text(["Hello."])], stop: "end_turn")),
        ])
        let chat = CoachChat(client: ClaudeClient(transport: transport, retryDelays: []))
        let conversation = CoachConversation(kind: .discussion, date: now)
        context.insert(conversation)

        await #expect(throws: CoachError.unauthorized) {
            try await chat.send(
                "Hi coach", in: conversation, model: "claude-opus-5-5", apiKey: "k", context: context, now: now,
                calendar: calendar)
        }
        // The athlete's message was kept, so it does not have to be typed again,
        // and the conversation knows it is still owed a reply.
        #expect(CoachChat.isAwaitingReply(conversation.messagesJSON))
        #expect(CoachChat.transcript(of: conversation.messagesJSON) == [.athlete(id: "m0b1", text: "Hi coach")])

        try await chat.send(
            nil, in: conversation, model: "claude-opus-5-5", apiKey: "k", context: context, now: now, calendar: calendar
        )
        #expect(try messages(transport.requests[1]) == (try messages(transport.requests[0])))
        #expect(CoachChat.transcript(of: conversation.messagesJSON).last == .coach(id: "m1b0", text: "Hello."))
        #expect(!CoachChat.isAwaitingReply(conversation.messagesJSON))
        #expect(!CoachChat.isAwaitingReply("[]"))

        // With nothing waiting for an answer, picking up does nothing.
        try await chat.send(
            nil, in: conversation, model: "claude-opus-5-5", apiKey: "k", context: context, now: now, calendar: calendar
        )
        #expect(transport.requests.count == 2)
    }

    @Test func badToolInputIsReportedBackNotApplied() async throws {
        let conversation = CoachConversation(kind: .discussion, date: now)
        context.insert(conversation)
        func run(_ name: String, _ json: String) -> CoachTools.Outcome {
            CoachTools.run(
                name, input: JSONValue.parse(json) ?? .null, toolUseID: "t", conversation: conversation, in: context,
                now: now, calendar: calendar)
        }
        #expect(run("save_athlete_details", #"{"availabilityHoursMonToSun":[1,2],"sports":null,"notes":null}"#).isError)
        #expect(
            run(
                "propose_plan",
                #"{"start":"\#(text(-5))","end":"\#(text(5))","goalTitle":null,"summary":"s","phases":[],"sessions":[]}"#
            ).isError)
        #expect(
            run(
                "propose_plan",
                #"{"start":"\#(text(1))","end":"\#(text(5))","goalTitle":null,"summary":"s","phases":[],"sessions":[]}"#
            ).isError)
        #expect(run("propose_changes", #"{"suggestions":"nope"}"#).isError)
        #expect(run("get_plan_sessions", #"{"from":"soon","to":"later"}"#).isError)
        #expect(run("launch_rockets", "{}").isError)
        #expect(try context.fetchCount(FetchDescriptor<PlanSuggestion>()) == 0)
        #expect(try context.fetch(FetchDescriptor<TrainingPlan>()).allSatisfy { !$0.isDraft })

        // Reading the plan returns live sessions with their short ids, and no drafts.
        let live = session(day: 3)
        let draft = TrainingPlan(name: "Draft", startDate: day(0), endDate: day(10))
        draft.isDraft = true
        context.insert(draft)
        let hidden = PlannedWorkout(date: day(3), sport: .swim, sessionType: .easy)
        context.insert(hidden)
        hidden.plan = draft
        let read = run("get_plan_sessions", #"{"from":"\#(text(0))","to":"\#(text(7))"}"#)
        #expect(!read.isError)
        #expect(read.text.contains(CoachTools.shortID(live)))
        #expect(!read.text.contains(CoachTools.shortID(hidden)))
    }
}
