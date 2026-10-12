import Analysis
@testable import Coach
import Foundation
import Models
import SwiftData
import Testing

@MainActor
@Suite struct WorkoutStructurerTests {
    let container: ModelContainer
    let context: ModelContext
    let session: PlannedWorkout

    init() throws {
        container = try LongGameStore.makeContainer(mode: .inMemory)
        context = container.mainContext
        let profile = AthleteProfile()
        profile.ftpWatts = 250
        profile.maxHR = 185
        profile.zoneUpperBoundsOverride = [120, 140, 155, 170]
        context.insert(profile)
        session = PlannedWorkout(date: Date(), sport: .bike, sessionType: .intervals, targetDurationSeconds: 3600, targetIntensity: "5 × 4 min at 105–110% FTP, 3 min easy")
        context.insert(session)
    }

    static let reply = """
        {"blocks":[{"repeats":1,"steps":[{"kind":"warmup","durationSeconds":900,"distanceMeters":null,"target":{"kind":"ftpPercent","low":50,"high":65},"note":null}]},\
        {"repeats":5,"steps":[{"kind":"work","durationSeconds":240,"distanceMeters":null,"target":{"kind":"ftpPercent","low":105,"high":110},"note":"smooth"},\
        {"kind":"recovery","durationSeconds":180,"distanceMeters":null,"target":{"kind":"ftpPercent","low":50,"high":50},"note":null}]},\
        {"repeats":1,"steps":[{"kind":"cooldown","durationSeconds":600,"distanceMeters":null,"target":null,"note":null}]}]}
        """

    func structurer(replying reply: String) -> (WorkoutStructurer, MockTransport) {
        let transport = MockTransport([.response(status: 200, lines: MockTransport.events(chunks: [String(reply.prefix(60)), String(reply.dropFirst(60))]))])
        return (WorkoutStructurer(client: ClaudeClient(transport: transport, retryDelays: [])), transport)
    }

    @Test func aSessionComesBackAsSteps() async throws {
        let (structurer, transport) = structurer(replying: Self.reply)
        let workout = try await structurer.structure(session, model: "claude-haiku-5-5", apiKey: "key", in: context)
        #expect(workout.lines() == ["Warm up 15 min at 50–65% FTP", "5 × (4 min at 105–110% FTP (smooth), recovery 3 min at 50% FTP)", "Cool down 10 min"])
        #expect(workout.estimatedDurationSeconds == 3600.0)

        // Only the session and the athlete's thresholds are sent.
        let body = try jsonBody(transport.requests.first)
        let user = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        let sent = try JSONDecoder().decode(WorkoutStructurer.Payload.self, from: Data(user.utf8))
        #expect(sent.session == .init(sport: "bike", sessionType: "intervals", durationMinutes: 60, intensity: "5 × 4 min at 105–110% FTP, 3 min easy"))
        #expect(sent.athlete == .init(ftpWatts: 250, zoneUpperBounds: [120, 140, 155, 170], maxHR: 185))
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")

        // The call is counted toward spend.
        let charges = try context.fetch(FetchDescriptor<CoachCharge>())
        #expect(charges.map(\.kind) == [.workoutStructure])
    }

    @Test func storingKeepsOnlyWhatIsUsable() throws {
        session.structure = try JSONDecoder().decode(StructuredWorkout.self, from: Data(Self.reply.utf8))
        #expect(session.structure?.blocks.count == 3)
        session.structure = StructuredWorkout(blocks: [.init(steps: [])])
        #expect(session.structureJSON == nil)
        session.structureJSON = "not json"
        #expect(session.structure == nil)
    }

    @Test func nonsenseIsRejected() async throws {
        let (structurer, _) = structurer(replying: "{\"blocks\":[]}")
        await #expect(throws: CoachError.malformed) {
            try await structurer.structure(session, model: "claude-haiku-5-5", apiKey: "key", in: context)
        }
    }

    @Test func onlyRunsAndRidesCanBeStructured() {
        #expect(WorkoutStructurer.canStructure(session))
        #expect(!WorkoutStructurer.canStructure(PlannedWorkout(date: Date(), sport: .swim, sessionType: .easy)))
        #expect(!WorkoutStructurer.canStructure(PlannedWorkout(date: Date(), sport: .run, sessionType: .rest)))
    }
}
