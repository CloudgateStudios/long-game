import Analysis
import Foundation
import Testing

@Suite struct StructuredWorkoutTests {
    typealias Step = StructuredWorkout.Step
    typealias Target = StructuredWorkout.Target

    let ride = StructuredWorkout(blocks: [
        .init(steps: [Step(.warmup, seconds: 600, target: Target(.ftpPercent, 50, 65))]),
        .init(
            repeats: 5,
            steps: [
                Step(.work, seconds: 240, target: Target(.ftpPercent, 105, 110), note: "high cadence"),
                Step(.recovery, seconds: 180, target: Target(.hrZone, 1)),
            ]),
        .init(steps: [Step(.cooldown, seconds: 600, target: Target(.hrZone, 1))]),
    ])

    let run = StructuredWorkout(blocks: [
        .init(steps: [Step(.warmup, seconds: 900, target: Target(.hrZone, 2))]),
        .init(
            repeats: 6,
            steps: [Step(.work, meters: 800, target: Target(.pace, 240, 250)), Step(.recovery, seconds: 90)]),
        .init(steps: [Step(.cooldown)]),
    ])

    @Test func textIsDerivedFromTheSteps() {
        #expect(
            ride.lines() == [
                "Warm up 10 min at 50–65% FTP",
                "5 × (4 min at 105–110% FTP (high cadence), recovery 3 min at Z1)",
                "Cool down 10 min at Z1",
            ])
        #expect(
            run.lines() == [
                "Warm up 15 min at Z2",
                "6 × (800 m at 4:00–4:10/km, recovery 1:30 min)",
                "Cool down until lap",
            ])
        #expect(run.lines(.init(paceUnit: .perMile))[1] == "6 × (800 m at 6:26–6:42/mi, recovery 1:30 min)")
    }

    @Test func durationCountsRepeatsAndEstimatesDistanceSteps() {
        #expect(ride.estimatedDurationSeconds == 3300.0)
        // The cool-down runs until the lap button, so the run's length is not known.
        #expect(run.estimatedDurationSeconds == nil)
        let timed = StructuredWorkout(blocks: Array(run.blocks.dropLast()))
        #expect(timed.estimatedDurationSeconds.map { Int($0) } == 900 + 6 * (196 + 90) - 1)
    }

    @Test func relativeTargetsResolveAgainstTheAthlete() {
        let athlete = TrainingThresholds(ftpWatts: 250, hrZoneUpperBounds: [120, 140, 155, 170], maxHR: 185)
        #expect(Target(.ftpPercent, 105, 110).watts(athlete) == 263...275)
        #expect(Target(.ftpPercent, 105, 110).watts(TrainingThresholds()) == nil)
        #expect(Target(.hrZone, 2).beatsPerMinute(athlete) == 120...140)
        #expect(Target(.hrZone, 1).beatsPerMinute(athlete) == 102...120)
        #expect(Target(.hrZone, 4, 5).beatsPerMinute(athlete) == 155...185)
        #expect(Target(.hrZone, 2).beatsPerMinute(TrainingThresholds()) == nil)
        #expect(Target(.pace, 240, 250).metersPerSecond == 4.0...(1000.0 / 240))
        #expect(Target(.power, 200, 250).ftpFraction(athlete) == 0.8...1.0)
        #expect(Target(.hrZone, 2).ftpFraction(athlete) == nil)
        #expect(Target(.hrZone, 2).ftpFraction(athlete, approximatingZones: true) == 0.56...0.75)
    }

    @Test func normalizingDropsWhatCannotBeTrusted() {
        let messy = StructuredWorkout(blocks: [
            .init(repeats: 0, steps: [Step(.work, seconds: -5, meters: 400, target: Target(.hrZone, 9), note: "  ")]),
            .init(repeats: 500, steps: [Step(.work, seconds: 60, meters: 400, target: Target(.ftpPercent, 120, 90))]),
            .init(steps: []),
        ]).normalized()
        #expect(messy.blocks.count == 2)
        #expect(messy.blocks[0] == .init(repeats: 1, steps: [Step(.work, meters: 400)]))
        #expect(
            messy.blocks[1]
                == .init(repeats: 99, steps: [Step(.work, seconds: 60, target: Target(.ftpPercent, 90, 120))]))
    }

    @Test func itSurvivesJSON() throws {
        let data = try JSONEncoder().encode(run)
        #expect(try JSONDecoder().decode(StructuredWorkout.self, from: data) == run)
    }
}
