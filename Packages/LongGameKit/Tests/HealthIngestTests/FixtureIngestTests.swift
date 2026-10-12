import Analysis
import Foundation
import HealthIngest
import Models
import SwiftData
import Testing

@Suite struct FixtureIngestTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    var lastNinetyDays: DateInterval {
        DateInterval(start: now.addingTimeInterval(-90 * 86_400), end: now)
    }

    @Test func fixtureCoversEverySportAndSource() async throws {
        let source = try FixtureHealthDataSource(now: now)
        let workouts = try await source.workouts(in: lastNinetyDays)

        #expect(Set(workouts.map(\.sport)) == Set(Sport.allCases))
        #expect(Set(workouts.map(\.sourceName)).isSuperset(of: ["Apple Watch", "Wahoo"]))
        #expect(workouts.contains { $0.heartRate.isEmpty })
        #expect(workouts.contains { $0.sessionID != nil })
        #expect(workouts.allSatisfy { lastNinetyDays.contains($0.start) })
        #expect(Set(workouts.map(\.id)).count == workouts.count)
    }

    @Test func fixtureHasADayOfMetricsForEveryDay() async throws {
        let source = try FixtureHealthDataSource(now: now)
        let days = try await source.dailyMetrics(in: lastNinetyDays)
        #expect(days.count >= 90)
        #expect(days.allSatisfy { $0.restingHR != nil && $0.hrvSDNN != nil && $0.sleepSeconds != nil })
    }

    @Test func firstSyncBackfillsAndLaterSyncsAddNothing() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let source = try FixtureHealthDataSource(now: now)
        let ingestor = HealthIngestor(modelContainer: container)
        let state = InMemorySyncStateStore()

        let first = try await ingestor.sync(from: source, state: state, now: now)
        let second = try await ingestor.sync(from: source, state: state, now: now)

        #expect(first.workoutsInserted > 50)
        #expect(first.workoutsUpdated == 0)
        #expect(first.daysUpserted >= 90)
        #expect(second.workoutsInserted == 0)
        #expect(second.workoutsUpdated == 0)
        // Later syncs only re-read the last few days of daily metrics.
        #expect(second.daysUpserted == AnalysisConstants.dailyMetricsLookbackDays + 1)
        #expect(state.data(for: .workoutAnchor) != nil)

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<CompletedWorkout>()) == first.workoutsInserted)
        #expect(try context.fetchCount(FetchDescriptor<DailyMetrics>()) == first.daysUpserted)
        #expect(try context.fetchCount(FetchDescriptor<AthleteProfile>()) == 1)
    }

    @Test func syncReportsItsStepsInOrder() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let steps = StepLog()
        try await HealthIngestor(modelContainer: container)
            .sync(from: try FixtureHealthDataSource(now: now), state: InMemorySyncStateStore(), now: now) { steps.add($0) }
        let seen = steps.values
        #expect(seen.first == .readingProfile)
        #expect(seen.last == .saving)
        #expect(seen.contains(.readingDailyMetrics))
        // The workout count becomes known part way through.
        #expect(seen.contains(.readingWorkouts(done: 0, total: 0)))
        #expect(seen.contains { if case .readingWorkouts(let done, let total) = $0 { done == total && total > 50 } else { false } })
    }

    @Test func resyncingFromScratchUpdatesInPlace() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let source = try FixtureHealthDataSource(now: now)
        let ingestor = HealthIngestor(modelContainer: container)

        let first = try await ingestor.sync(from: source, state: InMemorySyncStateStore(), now: now)
        let again = try await ingestor.sync(from: source, state: InMemorySyncStateStore(), now: now)

        #expect(again.workoutsInserted == 0)
        #expect(again.workoutsUpdated == first.workoutsInserted)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<CompletedWorkout>()) == first.workoutsInserted)
    }

    @Test func workoutsWithoutHeartRateAreLowerConfidence() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        try await HealthIngestor(modelContainer: container)
            .sync(from: try FixtureHealthDataSource(now: now), state: InMemorySyncStateStore(), now: now)

        let workouts = try ModelContext(container).fetch(FetchDescriptor<CompletedWorkout>())
        let withoutHR = workouts.filter { $0.averageHR == nil }
        #expect(!withoutHR.isEmpty)
        #expect(withoutHR.allSatisfy { $0.confidence == .estimated && $0.heartRateHistogram == nil })
        let withHR = workouts.filter { $0.averageHR != nil }
        #expect(withHR.allSatisfy { $0.confidence == .measured })
        // The histogram accounts for the whole workout, to within a sample.
        #expect(withHR.allSatisfy { abs(($0.heartRateHistogram ?? []).reduce(0, +) - $0.durationSeconds) <= 60 })
        #expect(workouts.allSatisfy { $0.source == .fixture })
    }

    @Test func ridesRecordedTwiceCountOnce() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        try await HealthIngestor(modelContainer: container)
            .sync(from: try FixtureHealthDataSource(now: now), state: InMemorySyncStateStore(), now: now)

        let workouts = try ModelContext(container).fetch(FetchDescriptor<CompletedWorkout>())
        let duplicates = workouts.filter { !$0.isPrimary }
        #expect(duplicates.count >= 10)
        // The bike computer has power, so the watch's copy is the one set aside.
        #expect(duplicates.allSatisfy { $0.sport == .bike && $0.sourceName == "Apple Watch" })
        for duplicate in duplicates {
            let partners = workouts.filter {
                $0.isPrimary && DuplicateResolver.isSameSession($0.sessionCandidate, duplicate.sessionCandidate)
            }
            #expect(partners.count == 1)
            #expect(partners.first?.sourceName == "Wahoo")
        }
    }

    @Test func aManualChoiceSurvivesTheNextSync() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let source = try FixtureHealthDataSource(now: now)
        let ingestor = HealthIngestor(modelContainer: container)
        try await ingestor.sync(from: source, state: InMemorySyncStateStore(), now: now)

        let context = ModelContext(container)
        let workouts = try context.fetch(FetchDescriptor<CompletedWorkout>())
        let watch = try #require(workouts.first { !$0.isPrimary })
        let wahoo = try #require(workouts.first {
            $0.isPrimary && DuplicateResolver.isSameSession($0.sessionCandidate, watch.sessionCandidate)
        })
        watch.isPrimary = true
        watch.isPrimaryManuallySet = true
        wahoo.isPrimary = false
        try context.save()
        let (watchID, wahooID) = (watch.externalID, wahoo.externalID)

        try await ingestor.sync(from: source, state: InMemorySyncStateStore(), now: now)

        let after = try ModelContext(container).fetch(FetchDescriptor<CompletedWorkout>())
        #expect(after.first { $0.externalID == watchID }?.isPrimary == true)
        #expect(after.first { $0.externalID == wahooID }?.isPrimary == false)
    }

    @Test func deletedWorkoutsAreRemovedWithTheirLegs() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let ingestor = HealthIngestor(modelContainer: container)
        let session = UUID()
        let single = HealthWorkoutRecord(id: UUID(), sourceName: "Watch", sport: .run, activityName: "Running", start: now, durationSeconds: 1800)
        let legs = [Sport.bike, .run].enumerated().map { index, sport in
            HealthWorkoutRecord(id: UUID(), sourceName: "Watch", sport: sport, activityName: "Leg", sessionID: session,
                                start: now.addingTimeInterval(-86_400 + Double(index) * 4000), durationSeconds: 3600)
        }
        let state = InMemorySyncStateStore()
        let source = ScriptedSource(steps: [
            WorkoutChanges(upserted: [single] + legs, anchor: Data([1])),
            WorkoutChanges(deletedIDs: [single.id, session], anchor: Data([2])),
        ])

        let first = try await ingestor.sync(from: source, state: state, now: now)
        #expect(first.workoutsInserted == 3)
        let second = try await ingestor.sync(from: source, state: state, now: now)
        #expect(second.workoutsDeleted == 3)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<CompletedWorkout>()) == 0)
        #expect(state.data(for: .workoutAnchor) == Data([2]))
    }

    @Test func aFailedSyncDoesNotAdvanceTheAnchor() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let state = InMemorySyncStateStore()
        let source = ScriptedSource(steps: [])
        await #expect(throws: ScriptedSource.Exhausted.self) {
            try await HealthIngestor(modelContainer: container).sync(from: source, state: state, now: now)
        }
        #expect(state.data(for: .workoutAnchor) == nil)
        #expect(state.date(for: .lastDailySync) == nil)
    }

    @Test func syncFillsProfileGapsWithoutOverwriting() async throws {
        let container = try LongGameStore.makeContainer(mode: .inMemory)
        let context = ModelContext(container)
        let profile = AthleteProfile()
        profile.heightCm = 175
        context.insert(profile)
        try context.save()

        try await HealthIngestor(modelContainer: container)
            .sync(from: try FixtureHealthDataSource(now: now), state: InMemorySyncStateStore(), now: now)

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<AthleteProfile>()).first)
        #expect(stored.heightCm == 175)
        #expect(stored.biologicalSex == .male)
        #expect(stored.dateOfBirth != nil)
        #expect(stored.weightKg != nil)
    }
}

/// Returns a scripted sequence of workout changes, one per sync.
private final class ScriptedSource: HealthDataSource, @unchecked Sendable {
    struct Exhausted: Error {}

    let workoutSource: WorkoutSource = .healthKit
    let isAvailable = true
    private var steps: [WorkoutChanges]

    init(steps: [WorkoutChanges]) {
        self.steps = steps
    }

    func needsAuthorization() async -> Bool { false }
    func requestAuthorization() async throws {}
    func profile() async throws -> HealthProfileRecord { HealthProfileRecord() }
    func dailyMetrics(in interval: DateInterval) async throws -> [HealthDailyRecord] { [] }
    func observeWorkouts(onChange: @escaping @Sendable () async -> Void) async throws {}

    func workoutChanges(since anchor: Data?, from start: Date, onProgress: @Sendable (Int, Int) -> Void) async throws -> WorkoutChanges {
        guard !steps.isEmpty else { throw Exhausted() }
        return steps.removeFirst()
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [SyncStep] = []

    func add(_ step: SyncStep) { lock.withLock { steps.append(step) } }
    var values: [SyncStep] { lock.withLock { steps } }
}
