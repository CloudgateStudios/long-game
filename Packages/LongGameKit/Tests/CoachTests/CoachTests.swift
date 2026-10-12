import Analysis
import Foundation
import Models
import SwiftData
import Testing

@testable import Coach

/// Replays scripted responses and records the requests it was sent.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Step {
        case response(status: Int, lines: [String])
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let step: Step = lock.withLock {
            requests.append(request)
            return steps.isEmpty ? .failure(.unknown) : steps.removeFirst()
        }
        switch step {
        case .failure(let code):
            throw URLError(code)
        case .response(let status, let lines):
            return (
                status,
                AsyncThrowingStream { continuation in
                    for line in lines { continuation.yield(line) }
                    continuation.finish()
                }
            )
        }
    }

    /// Server-sent events for a reply whose text arrives in the given chunks.
    static func events(chunks: [String], stopReason: String = "end_turn", model: String = "claude-opus-5-5") -> [String]
    {
        func data(_ object: [String: Any]) -> String {
            "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        var lines = [
            "event: message_start",
            data([
                "type": "message_start",
                "message": ["model": model, "usage": ["input_tokens": 1200, "output_tokens": 1]],
            ]),
            data(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]),
            data(["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]]),
            "event: ping",
            data(["type": "ping"]),
        ]
        lines += chunks.map {
            data(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": $0]])
        }
        lines += [
            data(["type": "message_delta", "delta": ["stop_reason": stopReason], "usage": ["output_tokens": 340]]),
            data(["type": "message_stop"]),
        ]
        return lines
    }
}

struct MissingBody: Error {}

func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
    guard let data = request?.httpBody, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw MissingBody() }
    return object
}

let sampleReply =
    #"{"assessment":"Solid week.\nRun volume is on track.","flags":["HRV dipped twice"],"suggestions":[]}"#

@Suite struct ClaudeClientTests {
    func client(_ transport: MockTransport) -> ClaudeClient {
        ClaudeClient(transport: transport, retryDelays: [.zero, .zero])
    }

    @Test func buildsTheRequestTheAPIExpects() throws {
        let request = try ClaudeClient.request(
            apiKey: "  test-key\n", model: "claude-opus-5-5", system: "sys", user: "{}", schema: CoachResponse.schema)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        let body = try jsonBody(request)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["fallbacks"] as? String == "default")
        // These are rejected by current models, so they must never be sent.
        #expect(body["thinking"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(body["temperature"] == nil)
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "high")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["assessment", "flags", "suggestions", "title"])
    }

    @Test func modelsWithoutAFallbackDoNotAskForOne() throws {
        let request = try ClaudeClient.request(
            apiKey: "k", model: "claude-haiku-5-5", system: "", user: "", schema: [:])
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let body = try jsonBody(request)
        #expect(body["fallbacks"] == nil)
    }

    @Test func anEmptyKeyNeverReachesTheNetwork() async {
        let transport = MockTransport([])
        await #expect(throws: CoachError.missingAPIKey) {
            try await client(transport).send(apiKey: "  ", model: "claude-opus-5-5", system: "", user: "")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func assemblesAStreamedReply() async throws {
        let transport = MockTransport([
            .response(status: 200, lines: MockTransport.events(chunks: ["{\"assess", "ment\":\"Hi\"", "}"]))
        ])
        let seen = Collector()
        let message = try await client(transport).send(apiKey: "k", model: "claude-opus-5-5", system: "", user: "") {
            await seen.add($0)
        }
        #expect(message.text == "{\"assessment\":\"Hi\"}")
        #expect(message.model == "claude-opus-5-5")
        #expect(message.stopReason == "end_turn")
        #expect(message.usage == ClaudeUsage(inputTokens: 1200, outputTokens: 340))
        #expect(await seen.values == ["{\"assess", "{\"assessment\":\"Hi\"", "{\"assessment\":\"Hi\"}"])
    }

    @Test func mapsHTTPErrors() async {
        func error(_ status: Int, _ type: String) async -> CoachError? {
            let body = "{\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"nope\"}}"
            // Enough copies for the retries a retryable status gets.
            let transport = MockTransport(Array(repeating: .response(status: status, lines: [body]), count: 3))
            do {
                _ = try await client(transport).send(apiKey: "k", model: "claude-opus-5-5", system: "", user: "")
                return nil
            } catch {
                return error as? CoachError
            }
        }
        #expect(await error(401, "authentication_error") == .unauthorized)
        #expect(await error(429, "rate_limit_error") == .rateLimited)
        #expect(await error(529, "overloaded_error") == .overloaded)
        #expect(await error(400, "invalid_request_error") == .api(status: 400, message: "nope"))
        #expect(await error(500, "api_error") == .api(status: 500, message: "nope"))
    }

    @Test func retriesTransientFailuresThenSucceeds() async throws {
        let transport = MockTransport([
            .failure(.networkConnectionLost),
            .response(status: 529, lines: ["{\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}"]),
            .response(status: 200, lines: MockTransport.events(chunks: [sampleReply])),
        ])
        let message = try await client(transport).send(apiKey: "k", model: "claude-opus-5-5", system: "", user: "")
        #expect(message.text == sampleReply)
        #expect(transport.requests.count == 3)
    }

    @Test func doesNotRetryARejectedKeyOrBadRequest() async {
        for (status, type) in [(401, "authentication_error"), (400, "invalid_request_error")] {
            let transport = MockTransport([
                .response(status: status, lines: ["{\"error\":{\"type\":\"\(type)\",\"message\":\"x\"}}"])
            ])
            _ = try? await client(transport).send(apiKey: "k", model: "claude-opus-5-5", system: "", user: "")
            #expect(transport.requests.count == 1)
        }
    }

    @Test func givesUpAfterTheRetryLimit() async {
        let transport = MockTransport(Array(repeating: .failure(.notConnectedToInternet), count: 5))
        await #expect(throws: CoachError.offline) {
            try await client(transport).send(apiKey: "k", model: "claude-opus-5-5", system: "", user: "")
        }
        #expect(transport.requests.count == 3)
    }

    @Test func reportsTimeoutsRefusalsAndCutOffReplies() async {
        await #expect(throws: CoachError.timedOut) {
            try await client(MockTransport(Array(repeating: .failure(.timedOut), count: 3))).send(
                apiKey: "k", model: "m", system: "", user: "")
        }
        await #expect(throws: CoachError.refused) {
            try await client(
                MockTransport([.response(status: 200, lines: MockTransport.events(chunks: [], stopReason: "refusal"))])
            )
            .send(apiKey: "k", model: "m", system: "", user: "")
        }
        await #expect(throws: CoachError.truncated) {
            try await client(
                MockTransport([
                    .response(status: 200, lines: MockTransport.events(chunks: ["{\"assess"], stopReason: "max_tokens"))
                ])
            )
            .send(apiKey: "k", model: "m", system: "", user: "")
        }
    }

    @Test func anErrorEventMidStreamIsSurfaced() async {
        let lines = [#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]
        let transport = MockTransport(Array(repeating: .response(status: 200, lines: lines), count: 3))
        await #expect(throws: CoachError.overloaded) {
            try await client(transport).send(apiKey: "k", model: "m", system: "", user: "")
        }
    }
}

actor Collector {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

@Suite struct PartialJSONTests {
    @Test func readsAStringWhileItIsStillArriving() {
        #expect(PartialJSON.string(forKey: "assessment", in: "{\"assess") == nil)
        #expect(PartialJSON.string(forKey: "assessment", in: "{\"assessment\":") == nil)
        #expect(PartialJSON.string(forKey: "assessment", in: "{\"assessment\": \"Going we") == "Going we")
        #expect(PartialJSON.string(forKey: "assessment", in: "{\"assessment\":\"Done.\",\"flags\":[") == "Done.")
    }

    @Test func decodesEscapes() {
        // Ends on a lone backslash: the first half of an escape that has not arrived yet.
        let text = #"{"assessment":"Line one.\nShe said \"easy\" – fine\"#
        #expect(PartialJSON.string(forKey: "assessment", in: text) == "Line one.\nShe said \"easy\" – fine")
        // An escape split between chunks waits for its second half.
        #expect(PartialJSON.string(forKey: "assessment", in: #"{"assessment":"a\u20"#) == "a")
    }

    @Test func theSchemaMatchesTheTypesItIsDecodedInto() throws {
        let properties = try #require(CoachResponse.schema["properties"] as? [String: Any])
        let suggestions = try #require(properties["suggestions"] as? [String: Any])
        let item = try #require(suggestions["items"] as? [String: Any])
        let fields = try #require(item["properties"] as? [String: Any])
        let required = try #require(item["required"] as? [String])
        #expect(Set(fields.keys) == Set(required))

        // A reply with every optional field null decodes.
        let reply =
            #"{"assessment":"a","flags":[],"suggestions":[{"action":"remove","sessionId":"ab12cd34","date":null,"sport":null,"sessionType":null,"durationMinutes":null,"distanceKm":null,"intensity":null,"instructions":null,"rationale":"r"}]}"#
        let decoded = try JSONDecoder().decode(CoachResponse.self, from: Data(reply.utf8))
        #expect(decoded.suggestions == [CoachSuggestion(action: .remove, sessionId: "ab12cd34", rationale: "r")])
    }
}

@MainActor
@Suite struct CoachPipelineTests {
    let container: ModelContainer
    let context: ModelContext
    let calendar = Calendar.current
    let now: Date
    let plan: TrainingPlan

    init() throws {
        container = try LongGameStore.makeContainer(mode: .inMemory)
        context = container.mainContext
        now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)).addingTimeInterval(9 * 3600)

        let profile = AthleteProfile()
        profile.dateOfBirth = calendar.date(byAdding: .year, value: -38, to: now)
        profile.biologicalSex = .male
        profile.maxHR = 190
        profile.coachNotes = "Left knee gets sore after long descents."
        context.insert(profile)

        let goal = Goal(
            title: "Half Marathon", eventSport: .run, eventDistanceMeters: 21_097.5,
            targetDate: calendar.date(byAdding: .day, value: 90, to: now))
        context.insert(goal)
        plan = TrainingPlan(
            name: "Private plan name", startDate: calendar.date(byAdding: .day, value: -30, to: now)!,
            endDate: calendar.date(byAdding: .day, value: 60, to: now)!, goal: goal)
        context.insert(plan)
    }

    func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    @discardableResult
    func session(_ sport: Sport, day offset: Int, minutes: Double = 60, type: SessionType = .easy) -> PlannedWorkout {
        let session = PlannedWorkout(
            date: day(offset), sport: sport, sessionType: type, targetDurationSeconds: minutes * 60)
        context.insert(session)
        session.plan = plan
        return session
    }

    @discardableResult
    func workout(_ sport: Sport, day offset: Int, minutes: Double = 60, primary: Bool = true) -> CompletedWorkout {
        let workout = CompletedWorkout(
            externalID: UUID(), source: .healthKit, sport: sport, start: day(offset).addingTimeInterval(7 * 3600),
            durationSeconds: minutes * 60)
        workout.sourceName = "Secret Watch Name"
        workout.activityName = sport == .other ? "Hiking" : "Outdoor Run"
        workout.isPrimary = primary
        workout.load = minutes * 2
        context.insert(workout)
        return workout
    }

    func build() throws -> BuiltPayload {
        try PlanReconciler.reconcile(in: context, now: now, calendar: calendar)
        return try CoachPayloadBuilder.build(in: context, trigger: .onDemand, now: now, calendar: calendar)
    }

    @Test func payloadCarriesFeedbackAndBricks() throws {
        let bike = session(.bike, day: 2)
        let run = session(.run, day: 2, minutes: 20)
        session(.swim, day: 2)
        run.follow(bike)
        let done = workout(.run, day: -1)
        done.perceivedEffort = 8
        done.feel = .tired
        done.athleteNotes = "Legs heavy from the start."
        workout(.bike, day: -2)

        let payload = try build().payload
        let sessions = try #require(payload.plan?.sessions)
        // The run sits straight after the bike, and they share a label the swim does not have.
        #expect(sessions.map(\.sport) == ["bike", "run", "swim"])
        #expect(sessions[0].brick != nil)
        #expect(sessions[0].brick == sessions[1].brick)
        #expect(sessions[2].brick == nil)
        #expect(payload.workouts.map(\.rpe) == [nil, 8])
        #expect(payload.workouts.last?.feel == "tired")
        #expect(payload.workouts.last?.notes == "Legs heavy from the start.")
    }

    @Test func payloadCarriesSummariesButNothingIdentifying() throws {
        let done = session(.run, day: -2)
        session(.bike, day: 3, minutes: 90, type: .long)
        session(.run, day: 40)  // beyond the look-ahead
        workout(.run, day: -2, minutes: 55)
        workout(.other, day: -1, minutes: 120)
        workout(.bike, day: -3, primary: false)  // duplicate recording
        workout(.run, day: -45)  // older than the history window
        let metrics = DailyMetrics(date: day(-1))
        metrics.restingHR = 51
        metrics.sleepSeconds = 7.5 * 3600
        context.insert(metrics)

        let built = try build()
        let payload = built.payload

        #expect(payload.profile.age == 38)
        #expect(payload.profile.maxHR == 190)
        #expect(payload.profile.notes == "Left knee gets sore after long descents.")
        #expect(payload.goals.first?.daysAway == 90)
        #expect(payload.goals.first?.distanceKm == 21.1)

        #expect(payload.plan?.sessions.count == 2)
        let sent = try #require(payload.plan?.sessions.first)
        #expect(sent.status == "done")
        #expect(sent.percentOfTarget == 92)
        #expect(built.sessionIDs[sent.id] == done.uuid)
        #expect(sent.id.count == 8)

        #expect(payload.workouts.count == 2)
        #expect(payload.workouts.map(\.sport) == ["run", "other"])
        #expect(payload.workouts.first?.sessionId == sent.id)
        #expect(payload.workouts.last?.activity == "Hiking")
        #expect(payload.workouts.last?.sessionId == nil)
        #expect(payload.daily.first?.sleepHours == 7.5)
        #expect(payload.load.weeks.reduce(0) { $0 + $1.load } == 350)

        // The exact JSON is what is stored and shown, so check the text itself.
        #expect(built.json.contains("\"age\":38"))
        for forbidden in [
            "dateOfBirth", "Secret Watch Name", "sourceName", "Private plan name", "externalID", done.uuid.uuidString,
        ] {
            #expect(!built.json.contains(forbidden), "payload leaked \(forbidden)")
        }
        // Compact and stable: the same data always produces the same bytes.
        #expect(!built.json.contains("\n"))
        #expect(try build().json == built.json)
        #expect(try JSONDecoder().decode(CoachPayload.self, from: Data(built.json.utf8)) == payload)
    }

    @Test func exportTextCarriesThePromptAndTheSameData() throws {
        session(.run, day: 1)
        let built = try build()
        let text = CoachPayloadBuilder.exportText(for: built)
        #expect(text.contains("not a medical service"))
        #expect(text.contains(built.json))
        #expect(text.contains("plain prose"))
    }

    func reviewer(replying reply: String) -> (CoachReviewer, MockTransport) {
        let transport = MockTransport([
            .response(
                status: 200,
                lines: MockTransport.events(chunks: [String(reply.prefix(30)), String(reply.dropFirst(30))]))
        ])
        return (CoachReviewer(client: ClaudeClient(transport: transport, retryDelays: [])), transport)
    }

    @Test func aReviewIsStoredWithItsPayloadAndSuggestions() async throws {
        let target = session(.run, day: 2, minutes: 60, type: .tempo)
        try PlanReconciler.reconcile(in: context, now: now, calendar: calendar)
        let id = String(target.uuid.uuidString.prefix(8)).lowercased()
        let reply = """
            {"title":"'Short sleep, easier Wednesday.'","assessment":"Good consistency.","flags":["Sleep was short twice"],"suggestions":[\
            {"action":"modify","sessionId":"\(id)","date":null,"sport":null,"sessionType":"easy","durationMinutes":40,"distanceKm":null,"intensity":"Z2","instructions":null,"rationale":"Back off after two short nights."},\
            {"action":"add","sessionId":null,"date":"\(day(4).formatted(.iso8601.year().month().day()))","sport":"swim","sessionType":"easy","durationMinutes":30,"distanceKm":null,"intensity":null,"instructions":null,"rationale":"Easy aerobic work."}]}
            """
        let (reviewer, transport) = reviewer(replying: reply)
        let progress = Progress()
        let review = try await reviewer.run(
            trigger: .weekly, model: "claude-opus-5-5", apiKey: "k", in: context, now: now, calendar: calendar
        ) { progress.values.append($0) }

        #expect(review.assessment == "Good consistency.")
        // The coach's suggested name, tidied of its quotes and full stop.
        #expect(review.title == "Short sleep, easier Wednesday")
        SessionTitle.rename(review, to: "  Week 6 check-in ")
        #expect(review.title == "Week 6 check-in")
        #expect(review.flags == ["Sleep was short twice"])
        #expect(review.trigger == .weekly)
        #expect(review.inputTokens == 1200)
        #expect(review.outputTokens == 340)
        #expect(progress.values.last == "Good consistency.")

        // What was stored is byte for byte what was sent.
        let sentBody = try jsonBody(transport.requests.first)
        let sentMessages = try #require(sentBody["messages"] as? [[String: Any]])
        #expect(sentMessages.first?["content"] as? String == review.payloadJSON)
        #expect(sentBody["system"] as? String == CoachConfiguration.systemPrompt)

        let suggestions = (review.suggestions ?? []).sorted { $0.createdAt < $1.createdAt }
        #expect(suggestions.map(\.action) == [.modify, .add])
        #expect(suggestions.allSatisfy { $0.status == .pending })
        #expect(suggestions[0].targetWorkout === target)
        #expect(suggestions[0].targetSummary.contains("tempo run"))
        #expect(suggestions[1].targetWorkout == nil)
        // Nothing is applied until it is accepted.
        #expect(target.sessionType == .tempo)
        #expect(target.targetDurationSeconds == 3600)

        try SuggestionApplier.accept(suggestions[0], in: context, calendar: calendar)
        #expect(target.sessionType == .easy)
        #expect(target.targetDurationSeconds == 2400)
        #expect(target.targetIntensity == "Z2")
        #expect(target.sport == .run)  // null fields are left alone
        #expect(suggestions[0].status == .accepted)

        try SuggestionApplier.accept(suggestions[1], in: context, calendar: calendar)
        let added = try #require(plan.workouts(on: day(4), calendar: calendar).first)
        #expect(added.sport == .swim)
        #expect(added.targetDurationSeconds == 1800)

        // The next review is told what was said and what was taken up.
        let next = try CoachPayloadBuilder.build(
            in: context, trigger: .onDemand, now: now.addingTimeInterval(86_400), calendar: calendar)
        #expect(next.payload.previousReview?.assessment == "Good consistency.")
        #expect(next.payload.previousReview?.suggestions.map(\.status) == ["accepted", "accepted"])
    }

    @Test func moveRemoveAndReject() async throws {
        let moved = session(.run, day: 2)
        let removed = session(.bike, day: 3)
        let kept = session(.swim, day: 4)
        func record(_ suggestion: CoachSuggestion, target: PlannedWorkout?) throws -> PlanSuggestion {
            let record = PlanSuggestion(
                action: suggestion.action,
                proposedChangeJSON: String(decoding: try JSONEncoder().encode(suggestion), as: UTF8.self),
                rationale: suggestion.rationale)
            context.insert(record)
            record.targetWorkout = target
            return record
        }
        let newDate = day(5).formatted(.iso8601.year().month().day())

        try SuggestionApplier.accept(
            try record(CoachSuggestion(action: .move, date: newDate, rationale: "r"), target: moved), in: context,
            calendar: calendar)
        #expect(calendar.isDate(moved.day, inSameDayAs: day(5)))

        let removal = try record(CoachSuggestion(action: .remove, rationale: "r"), target: removed)
        try SuggestionApplier.accept(removal, in: context, calendar: calendar)
        #expect(plan.workouts(on: day(3), calendar: calendar).isEmpty)
        #expect(removal.status == .accepted)

        let rejected = try record(CoachSuggestion(action: .remove, rationale: "r"), target: kept)
        try SuggestionApplier.reject(rejected, in: context)
        #expect(rejected.status == .rejected)
        #expect(plan.workouts(on: day(4), calendar: calendar).count == 1)

        // A suggestion whose session has since gone cannot be applied.
        let orphan = try record(CoachSuggestion(action: .modify, durationMinutes: 30, rationale: "r"), target: nil)
        #expect(throws: SuggestionError.sessionGone) {
            try SuggestionApplier.accept(orphan, in: context, calendar: calendar)
        }
        #expect(orphan.status == .pending)
        let vague = try record(CoachSuggestion(action: .add, rationale: "r"), target: nil)
        #expect(throws: SuggestionError.incomplete) {
            try SuggestionApplier.accept(vague, in: context, calendar: calendar)
        }
    }

    @Test func aBrokenReplyStoresNothing() async throws {
        session(.run, day: 1)
        let (reviewer, _) = reviewer(replying: #"{"assessment":"cut off mid-sentence and never closed"#)
        await #expect(throws: CoachError.malformed) {
            _ = try await reviewer.run(
                trigger: .onDemand, model: "claude-opus-5-5", apiKey: "k", in: context, now: now, calendar: calendar)
        }
        #expect(try context.fetchCount(FetchDescriptor<CoachReview>()) == 0)

        await #expect(throws: CoachError.missingAPIKey) {
            _ = try await reviewer.run(
                trigger: .onDemand, model: "claude-opus-5-5", apiKey: nil, in: context, now: now, calendar: calendar)
        }
    }

    @Test func reviewsAreChargedAndOutliveTheReview() async throws {
        session(.run, day: 1)
        let (reviewer, _) = reviewer(replying: #"{"assessment":"ok","flags":[],"suggestions":[]}"#)
        let review = try await reviewer.run(
            trigger: .onDemand, model: "claude-opus-5-5", apiKey: "k", in: context, now: now, calendar: calendar)
        let charges = try context.fetch(FetchDescriptor<CoachCharge>())
        #expect(charges.count == 1)
        #expect(charges.first?.sessionID == review.uuid)
        #expect(charges.first?.date == now)
        // 1200 in and 340 out on Opus 5.5.
        #expect(abs((charges.first?.cost ?? 0) - (1200 * 4 + 340 * 20) / 1_000_000) < 1e-9)

        // Deleting the review does not erase what it cost.
        context.delete(review)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<CoachCharge>()) == 1)
    }

    @Test func costUsesTheModelsPrices() {
        #expect(CoachConfiguration.cost(model: "claude-opus-5-5", inputTokens: 20_000, outputTokens: 8_000) == 0.24)
        #expect(CoachConfiguration.cost(model: "unknown", inputTokens: 1, outputTokens: 1) == nil)
        #expect(CoachConfiguration.model(CoachConfiguration.defaultModel) != nil)
    }
}

@MainActor
final class Progress {
    var values: [String] = []
}
