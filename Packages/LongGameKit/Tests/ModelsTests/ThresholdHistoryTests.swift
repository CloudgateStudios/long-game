import Analysis
import Foundation
import Models
import SwiftData
import Testing

@MainActor
@Suite struct ThresholdHistoryTests {
    let container: ModelContainer
    let context: ModelContext
    let calendar = Calendar.current
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let athlete = AthleteProfile()

    init() throws {
        container = try LongGameStore.makeContainer(mode: .inMemory)
        context = container.mainContext
        athlete.maxHR = 190
        context.insert(athlete)
    }

    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    @discardableResult
    func ride(day offset: Int, watts: Double) -> CompletedWorkout {
        let workout = CompletedWorkout(
            externalID: UUID(), source: .healthKit, sport: .bike, start: day(offset), durationSeconds: 3600)
        workout.averagePowerWatts = watts
        var bins = Array(repeating: 0.0, count: AnalysisConstants.histogramBinCount)
        bins[Int((120 - AnalysisConstants.histogramLowestBPM) / AnalysisConstants.histogramBinWidth)] = 3600
        workout.heartRateHistogram = bins
        context.insert(workout)
        return workout
    }

    func snapshots() throws -> [ThresholdSnapshot] { try ThresholdHistory.snapshots(in: context) }

    @Test func raisingFTPLeavesEarlierRidesAlone() throws {
        athlete.ftpWatts = 200
        let old = ride(day: -30, watts: 200)
        try LoadRecalculator.recalculate(in: context, now: day(-30))
        let before = try #require(old.load)

        athlete.ftpWatts = 250
        let recent = ride(day: 0, watts: 250)
        try LoadRecalculator.recalculate(in: context, now: now)
        // Each ride was at threshold for the FTP of its day, so they score the same.
        #expect(old.load == before)
        #expect(recent.load == before)
        #expect(try snapshots().map(\.ftpWatts) == [200, 250])
        #expect(try snapshots().map(\.day) == [calendar.startOfDay(for: day(-30)), calendar.startOfDay(for: now)])
    }

    @Test func aFirstFTPReachesBackToRidesBeforeIt() throws {
        let old = ride(day: -30, watts: 200)
        try LoadRecalculator.recalculate(in: context, now: day(-30))
        let onHeartRate = try #require(old.load)

        athlete.ftpWatts = 200
        try LoadRecalculator.recalculate(in: context, now: now)
        // Nobody knew the FTP then; the first one entered is the best guess.
        #expect(old.load != onHeartRate)
        #expect(try snapshots().map(\.ftpWatts) == [nil, 200])
    }

    @Test func editsOnOneDayAreOneSnapshotAndNothingNewMeansNoSnapshot() throws {
        athlete.ftpWatts = 200
        try LoadRecalculator.recalculate(in: context, now: now)
        athlete.ftpWatts = 210
        try LoadRecalculator.recalculate(in: context, now: now.addingTimeInterval(600))
        try LoadRecalculator.recalculate(in: context, now: day(5))
        #expect(try snapshots().map(\.ftpWatts) == [210])
    }

    @Test func twoDevicesWritingTheSameDayLeaveOne() throws {
        athlete.ftpWatts = 200
        try LoadRecalculator.recalculate(in: context, now: now)
        let other = ThresholdSnapshot(date: now)
        other.date = try #require(try snapshots().first?.date)
        other.createdAt = now.addingTimeInterval(60)
        other.ftpWatts = 200
        other.zoneUpperBounds = try snapshots().first?.zoneUpperBounds
        context.insert(other)

        try LoadRecalculator.recalculate(in: context, now: now.addingTimeInterval(120))
        try context.save()
        #expect(try snapshots().map(\.uuid) == [other.uuid])
    }

    @Test func removingASnapshotHandsItsDaysToTheNeighbours() throws {
        athlete.ftpWatts = 200
        let old = ride(day: -30, watts: 250)
        try LoadRecalculator.recalculate(in: context, now: day(-30))
        let scoredAt200 = try #require(old.load)
        athlete.ftpWatts = 250
        try LoadRecalculator.recalculate(in: context, now: now)
        #expect(old.load == scoredAt200)

        // "My FTP was really 250 all along."
        context.delete(try #require(try snapshots().first))
        try context.save()
        try LoadRecalculator.recalculate(in: context, now: now)
        #expect(try #require(old.load) < scoredAt200)
    }
}
