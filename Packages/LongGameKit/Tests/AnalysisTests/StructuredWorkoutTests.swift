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

    @Test func theProfileLaysStepsOutOnOneScale() {
        let athlete = TrainingThresholds(ftpWatts: 250, hrZoneUpperBounds: [120, 140, 155, 170], maxHR: 185)
        let bars = ride.profile(sport: .bike, thresholds: athlete)
        // Repeats are written out: warm-up, five work and recovery pairs, cool-down.
        #expect(bars.count == 12)
        #expect(Array(bars.map(\.start).prefix(4)) == [0.0, 600, 840, 1020])
        let last = bars[bars.count - 1]
        #expect(last.start + last.seconds == 3300.0)
        #expect(bars.allSatisfy { $0.isTimed })
        // Percent of FTP and heart-rate zones land on the same scale.
        #expect(abs(bars[0].intensity - 0.575) < 0.0001 && bars[0].zone == 2)
        #expect(abs(bars[1].intensity - 1.075) < 0.0001 && bars[1].zone == 5)
        #expect(bars[2].intensity == 0.5 && bars[2].zone == 1)
    }

    @Test func theProfileCopesWithPaceDistanceAndOpenSteps() {
        let bars = run.profile(sport: .run)
        #expect(bars.count == 14)
        // 800 m at 4:00–4:10/km takes a little over three minutes.
        #expect(Int(bars[1].seconds) == 195 && bars[1].isTimed)
        // With no threshold pace and a single pace in the session, it is drawn as steady.
        #expect(bars[1].intensity == StructuredWorkoutConstants.assumedSteadyIntensity)
        // A recovery with no target is drawn easy; the lap-button cool-down has a nominal width.
        #expect(bars[2].zone == 1)
        #expect(!bars[13].isTimed && bars[13].seconds == StructuredWorkoutConstants.openStepSeconds)

        // With a threshold pace, pace is measured against it.
        let known = run.profile(sport: .run, thresholds: TrainingThresholds(thresholdRunPaceSecondsPerKm: 255))
        // 4:05/km against a 4:15 threshold is faster than threshold.
        #expect(known[1].zone == 5)
    }

    @Test func otherTargetsFindTheirZone() {
        let athlete = TrainingThresholds(ftpWatts: 250, hrZoneUpperBounds: [120, 140, 155, 170], maxHR: 185)
        func zone(_ target: Target) -> Int? {
            StructuredWorkout(blocks: [.init(steps: [Step(.work, seconds: 60, target: target)])])
                .profile(sport: .bike, thresholds: athlete).first?.zone
        }
        #expect(zone(Target(.heartRate, 125, 135)) == 2)
        #expect(zone(Target(.heartRate, 175, 180)) == 5)
        #expect(zone(Target(.power, 200, 210)) == 3)
        #expect(zone(Target(.rpe, 3)) == 2)
        #expect(zone(Target(.rpe, 9)) == 5)
        #expect(StructuredWorkout.zone(forIntensity: 3) == 5)
    }

    @Test func aRunCanBeShownByPaceOrByHeartRate() {
        // Threshold pace 4:30/km.
        let athlete = TrainingThresholds(
            hrZoneUpperBounds: [120, 140, 155, 170], maxHR: 185, thresholdRunPaceSecondsPerKm: 270)
        let byZone = StructuredWorkout(blocks: [
            .init(steps: [Step(.warmup, seconds: 600, target: Target(.hrZone, 2))]),
            .init(
                repeats: 4,
                steps: [Step(.work, seconds: 240, target: Target(.hrZone, 4)), Step(.recovery, seconds: 120)]),
            .init(steps: [Step(.cooldown, seconds: 300, target: Target(.heartRate, 105, 120))]),
        ])
        #expect(byZone.runTargetMode == .heartRate)
        #expect(byZone.needsConversion(to: .pace) && !byZone.needsConversion(to: .heartRate))

        let byPace = byZone.expressed(as: .pace, thresholds: athlete)
        #expect(
            byPace.lines() == [
                "Warm up 10 min at 5:10–5:50/km",
                "4 × (4 min at 4:25–4:45/km, recovery 2 min)",
                "Cool down 5 min at 5:50–6:30/km",
            ])
        #expect(byPace.runTargetMode == .pace)
        // Durations and structure are untouched.
        #expect(byPace.estimatedDurationSeconds == byZone.estimatedDurationSeconds)

        // In miles the paces are round numbers per mile.
        let perMile = byZone.expressed(as: .pace, thresholds: athlete, paceUnit: .perMile)
        #expect(perMile.lines(.init(paceUnit: .perMile))[1] == "4 × (4 min at 7:10–7:40/mi, recovery 2 min)")

        // And back: each pace lands in the zone it came from.
        let back = byPace.expressed(as: .heartRate, thresholds: athlete)
        #expect(back.lines() == ["Warm up 10 min at Z2", "4 × (4 min at Z4, recovery 2 min)", "Cool down 5 min at Z1"])

        // The chart puts both versions in the same zones.
        #expect(
            byPace.profile(sport: .run, thresholds: athlete).map(\.zone)
                == byZone.profile(sport: .run, thresholds: athlete).map(\.zone))
    }

    @Test func withoutAThresholdPaceNothingIsConverted() {
        let athlete = TrainingThresholds(hrZoneUpperBounds: [120, 140, 155, 170])
        #expect(run.expressed(as: .heartRate, thresholds: athlete) == run)
        let ride = self.ride.expressed(as: .pace, thresholds: TrainingThresholds(thresholdRunPaceSecondsPerKm: 270))
        // Power targets are left alone; only the heart-rate zone steps change.
        #expect(ride.blocks[0] == self.ride.blocks[0])
        #expect(
            self.ride.runTargetMode == .heartRate
                && StructuredWorkout(blocks: [self.ride.blocks[0]]).runTargetMode == nil)
    }
}
