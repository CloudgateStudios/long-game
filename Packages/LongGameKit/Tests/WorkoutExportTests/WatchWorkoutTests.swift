#if canImport(WorkoutKit)
import Analysis
import Foundation
import HealthKit
import Testing
import WorkoutKit
@testable import WorkoutExport

@Suite struct WatchWorkoutTests {
    func custom(_ plan: WorkoutPlan) throws -> CustomWorkout {
        guard case .custom(let workout) = plan.workout else { throw WorkoutExportError.empty }
        return workout
    }

    @Test func aRunBecomesWarmUpIntervalsAndCoolDown() throws {
        let id = UUID()
        let plan = try WatchWorkout.plan(for: Sample.run, id: id)
        #expect(plan.id == id)
        let workout = try custom(plan)
        #expect(workout.activity == .running)
        #expect(workout.location == .outdoor)
        #expect(workout.displayName == "6 × 800 m")

        #expect(workout.warmup?.goal == .time(900, .seconds))
        let warmupAlert = try #require(workout.warmup?.alert as? HeartRateRangeAlert)
        #expect(warmupAlert.target.lowerBound.value == 120 && warmupAlert.target.upperBound.value == 140)

        #expect(workout.blocks.count == 1)
        #expect(workout.blocks[0].iterations == 6)
        let work = workout.blocks[0].steps[0]
        #expect(work.purpose == .work)
        #expect(work.step.goal == .distance(800, .meters))
        #expect(work.step.displayName == "5K effort")
        let pace = try #require(work.step.alert as? SpeedRangeAlert)
        #expect(pace.target.lowerBound.converted(to: .metersPerSecond).value == 4.0)
        let recovery = workout.blocks[0].steps[1]
        #expect(recovery.purpose == .recovery)
        #expect(recovery.step.goal == .time(90, .seconds))
        #expect(recovery.step.alert == nil)

        #expect(workout.cooldown?.goal == .open)
    }

    @Test func aRideGetsPowerInWatts() throws {
        let workout = try custom(WatchWorkout.plan(for: Sample.ride))
        #expect(workout.activity == .cycling)
        #expect(workout.location == .indoor)
        // Warm-up and cool-down are lifted out; the steady step stays as its own block.
        #expect(workout.blocks.map(\.iterations) == [5, 1])
        let power = try #require(workout.blocks[0].steps[0].step.alert as? PowerRangeAlert)
        #expect(power.target.lowerBound.value == 263 && power.target.upperBound.value == 275)
    }

    @Test func withoutTheAthletesNumbersItFallsBackToTheWatchsZones() throws {
        var ride = Sample.ride
        ride.thresholds = TrainingThresholds()
        let workout = try custom(WatchWorkout.plan(for: ride))
        // No FTP, so no power alert rather than a wrong one.
        #expect(workout.blocks[0].steps[0].step.alert == nil)
        let zone = try #require(workout.blocks[1].steps[0].step.alert as? HeartRateZoneAlert)
        #expect(zone.zone == 2)
    }

    @Test func thePlanSurvivesBeingSavedAsAFile() throws {
        let plan = try WatchWorkout.plan(for: Sample.run)
        let data = try plan.dataRepresentation
        #expect(!data.isEmpty)
        #expect(try WorkoutPlan(from: data) == plan)
    }

    @Test func otherSportsAreRefused() {
        var swim = Sample.run
        swim.sport = .swim
        #expect(throws: WorkoutExportError.unsupportedSport) { try WatchWorkout.plan(for: swim) }
    }
}
#endif
