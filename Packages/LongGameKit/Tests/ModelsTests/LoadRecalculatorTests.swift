import Analysis
import Foundation
import Models
import SwiftData
import Testing

@MainActor
@Suite struct LoadRecalculatorTests {
    let container: ModelContainer
    let context: ModelContext
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try LongGameStore.makeContainer(mode: .inMemory)
        context = container.mainContext
    }

    func histogram(minutes: Double, bpm: Double) -> [Double] {
        var bins = Array(repeating: 0.0, count: AnalysisConstants.histogramBinCount)
        bins[Int((bpm - AnalysisConstants.histogramLowestBPM) / AnalysisConstants.histogramBinWidth)] = minutes * 60
        return bins
    }

    @discardableResult
    func log(_ sport: Sport, minutes: Double = 60, bpm: Double? = nil, power: Double? = nil, maxHR: Double? = nil) -> CompletedWorkout {
        let workout = CompletedWorkout(externalID: UUID(), source: .healthKit, sport: sport, start: now.addingTimeInterval(-86_400), durationSeconds: minutes * 60)
        workout.heartRateHistogram = bpm.map { histogram(minutes: minutes, bpm: $0) }
        workout.averageHR = bpm
        workout.maxHR = maxHR ?? bpm
        workout.averagePowerWatts = power
        context.insert(workout)
        return workout
    }

    @discardableResult
    func profile(maxHR: Double? = 190, ftp: Double? = nil) -> AthleteProfile {
        let profile = AthleteProfile()
        profile.maxHR = maxHR
        profile.ftpWatts = ftp
        context.insert(profile)
        return profile
    }

    @Test func storesLoadZonesAndConfidence() throws {
        profile()
        let run = log(.run, bpm: 120) // zone 2 of [114, 133, 152, 171]
        let ride = log(.bike, bpm: 120, power: 200)
        let yoga = log(.other, minutes: 50)

        #expect(try LoadRecalculator.recalculate(in: context, now: now) == 3)
        #expect(run.load == 120)
        #expect(run.zoneSeconds == [0, 3600, 0, 0, 0])
        #expect(run.confidence == .measured)
        // No FTP yet, so the ride is scored on heart rate.
        #expect(ride.load == 120)
        #expect(yoga.load == 100)
        #expect(yoga.zoneSeconds == nil)
        #expect(yoga.confidence == .estimated)

        // Nothing is rewritten when nothing changed.
        #expect(try LoadRecalculator.recalculate(in: context, now: now) == 0)
    }

    @Test func changingTheProfileRescoresWorkouts() throws {
        let athlete = profile()
        let run = log(.run, bpm: 120)
        let ride = log(.bike, bpm: 120, power: 200)
        try LoadRecalculator.recalculate(in: context, now: now)

        athlete.ftpWatts = 200
        athlete.zoneUpperBoundsOverride = [100, 115, 130, 150]
        #expect(try LoadRecalculator.recalculate(in: context, now: now) == 2)
        #expect(ride.load == 240) // power at FTP
        #expect(run.load == 180) // 120 bpm is now zone 3
        #expect(run.zoneSeconds == [0, 0, 3600, 0, 0])
    }

    @Test func anEstimateUsesTheMatchedSessionType() throws {
        profile()
        let workout = log(.run, minutes: 40)
        let session = PlannedWorkout(date: workout.start, sport: .run, sessionType: .intervals, targetDurationSeconds: 2400)
        context.insert(session)
        session.matchedWorkout = workout
        try LoadRecalculator.recalculate(in: context, now: now)
        #expect(workout.load == 160)
    }

    @Test func zonesFallBackThroughTheEvidence() throws {
        // No profile at all: the highest reading seen stands in for max heart rate.
        log(.run, bpm: 150, maxHR: 184)
        var zones = try LoadRecalculator.resolveZones(in: context, now: now)
        #expect(zones.maxHR == 184)
        #expect(zones.maxHRSource == .observed)
        #expect(zones.restingHR == nil)
        #expect(zones.bounds == HeartRateZones.upperBounds(maxHR: 184, restingHR: nil))

        // Recent resting heart rate switches the zones to heart-rate reserve.
        for offset in 1...5 {
            let day = DailyMetrics(date: now.addingTimeInterval(Double(-offset) * 86_400))
            day.restingHR = 50
            context.insert(day)
        }
        let athlete = profile(maxHR: nil)
        zones = try LoadRecalculator.resolveZones(in: context, now: now)
        #expect(zones.restingHR == 50)
        #expect(zones.bounds == HeartRateZones.upperBounds(maxHR: 184, restingHR: 50))
        #expect(!zones.isOverridden)

        athlete.maxHR = 192
        athlete.restingHRBaseline = 48
        zones = try LoadRecalculator.resolveZones(in: context, now: now)
        #expect(zones.maxHRSource == .manual)
        #expect(zones.bounds == HeartRateZones.upperBounds(maxHR: 192, restingHR: 48))
    }

    @Test func duplicatesStayOutOfTheTrend() throws {
        profile()
        let counted = log(.bike, bpm: 120)
        let duplicate = log(.bike, bpm: 120)
        duplicate.isPrimary = false
        try LoadRecalculator.recalculate(in: context, now: now)
        #expect(counted.loadEntry?.load == 120)
        #expect(duplicate.load == 120)
        #expect(duplicate.loadEntry == nil)
    }
}
