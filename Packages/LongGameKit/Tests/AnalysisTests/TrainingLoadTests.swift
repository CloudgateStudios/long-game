import Analysis
import Foundation
import Testing

@Suite struct HeartRateZonesTests {
    @Test func zonesFromMaxAlone() {
        #expect(HeartRateZones.upperBounds(maxHR: 190, restingHR: nil) == [114, 133, 152, 171])
    }

    @Test func zonesFromReserveWhenRestingIsKnown() {
        // Reserve is 140: 50 + 0.6 × 140 = 134, and so on.
        #expect(HeartRateZones.upperBounds(maxHR: 190, restingHR: 50) == [134, 148, 162, 176])
    }

    @Test func aNonsenseRestingRateIsIgnored() {
        #expect(
            HeartRateZones.upperBounds(maxHR: 190, restingHR: 200)
                == HeartRateZones.upperBounds(maxHR: 190, restingHR: nil))
    }

    @Test func aManualOverrideWins() {
        #expect(
            HeartRateZones.resolve(override: [120, 140, 155, 170], maxHR: 190, restingHR: 50) == [120, 140, 155, 170])
        // A malformed override falls back to the derived zones.
        #expect(
            HeartRateZones.resolve(override: [140, 120, 155, 170], maxHR: 190, restingHR: nil) == [114, 133, 152, 171])
        #expect(HeartRateZones.resolve(override: [120, 140], maxHR: 190, restingHR: nil) == [114, 133, 152, 171])
        #expect(HeartRateZones.resolve(override: nil, maxHR: nil, restingHR: 50) == nil)
    }

    @Test func maxHeartRatePrefersManualThenTheHigherEvidence() {
        #expect(HeartRateZones.maxHeartRate(manual: 185, observed: 192, age: 40)?.value == 185)
        #expect(HeartRateZones.maxHeartRate(manual: 185, observed: 192, age: 40)?.source == .manual)
        // Age 40 estimates 180.
        #expect(HeartRateZones.maxHeartRate(manual: nil, observed: 192, age: 40)?.source == .observed)
        #expect(HeartRateZones.maxHeartRate(manual: nil, observed: 150, age: 40)?.value == 180)
        #expect(HeartRateZones.maxHeartRate(manual: nil, observed: 150, age: 40)?.source == .ageEstimate)
        #expect(HeartRateZones.maxHeartRate(manual: nil, observed: nil, age: nil) == nil)
    }
}

@Suite struct WorkoutLoadTests {
    let bounds: [Double] = [114, 133, 152, 171]

    func histogram(_ minutesAtBPM: [(Double, Double)]) -> [Double] {
        var bins = Array(repeating: 0.0, count: AnalysisConstants.histogramBinCount)
        for (minutes, bpm) in minutesAtBPM {
            bins[Int((bpm - AnalysisConstants.histogramLowestBPM) / AnalysisConstants.histogramBinWidth)] +=
                minutes * 60
        }
        return bins
    }

    @Test func heartRateLoadIsZoneWeightedMinutes() {
        // 30 min in zone 2 and 10 min in zone 4: 30 × 2 + 10 × 4.
        let input = WorkoutLoad.Input(
            sport: .run, durationSeconds: 2400, heartRateHistogram: histogram([(30, 120), (10, 160)]))
        let result = WorkoutLoad.compute(input, zoneBounds: bounds, ftpWatts: nil)
        #expect(result.method == .heartRate)
        #expect(result.load == 100)
        #expect(result.zoneSeconds == [0, 1800, 0, 600, 0])
    }

    @Test func ridesPreferPowerWhenFTPIsKnown() {
        let input = WorkoutLoad.Input(
            sport: .bike, durationSeconds: 3600, heartRateHistogram: histogram([(60, 120)]), averagePowerWatts: 200)
        let atFTP = WorkoutLoad.compute(input, zoneBounds: bounds, ftpWatts: 200)
        #expect(atFTP.method == .power)
        #expect(atFTP.load == 240)
        // Zone times are still reported alongside a power-based load.
        #expect(atFTP.zoneSeconds == [0, 3600, 0, 0, 0])
        #expect(abs(WorkoutLoad.compute(input, zoneBounds: bounds, ftpWatts: 250).load - 153.6) < 0.0001)
        // No FTP: fall back to heart rate.
        #expect(WorkoutLoad.compute(input, zoneBounds: bounds, ftpWatts: nil).method == .heartRate)
    }

    @Test func powerDoesNotApplyToRuns() {
        let input = WorkoutLoad.Input(
            sport: .run, durationSeconds: 3600, heartRateHistogram: histogram([(60, 120)]), averagePowerWatts: 300)
        #expect(WorkoutLoad.compute(input, zoneBounds: bounds, ftpWatts: 250).method == .heartRate)
    }

    @Test func withoutSamplesLoadIsEstimatedFromDuration() {
        let plain = WorkoutLoad.Input(sport: .other, durationSeconds: 3000)
        let estimate = WorkoutLoad.compute(plain, zoneBounds: bounds, ftpWatts: nil)
        #expect(estimate.load == 100)
        #expect(estimate.zoneSeconds == nil)
        #expect(estimate.method == .estimated)
        let tempo = WorkoutLoad.Input(sport: .run, durationSeconds: 3000, sessionType: .tempo)
        #expect(WorkoutLoad.compute(tempo, zoneBounds: bounds, ftpWatts: nil).load == 175)
        // Heart rate without zones cannot be weighted either.
        let noZones = WorkoutLoad.Input(sport: .run, durationSeconds: 3000, heartRateHistogram: histogram([(50, 150)]))
        #expect(WorkoutLoad.compute(noZones, zoneBounds: nil, ftpWatts: nil).method == .estimated)
    }
}

@Suite struct LoadTrendTests {
    let calendar = Calendar(identifier: .gregorian)
    var today: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)) }

    func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    @Test func steadyTrainingHasARatioOfOne() throws {
        let entries = (-40...0).map { LoadEntry(date: day($0).addingTimeInterval(7 * 3600), sport: .run, load: 100) }
        let days = LoadTrend.days(entries, from: day(-6), to: day(0), calendar: calendar)
        #expect(days.count == 7)
        let last = try #require(days.last)
        #expect(last.total == 100)
        #expect(last.acute == 100)
        #expect(last.chronic == 100)
        #expect(last.ratio == 1)
        #expect(!last.isRatioFlagged)
    }

    @Test func aSuddenRampIsFlagged() throws {
        var entries = (-40...(-7)).map { LoadEntry(date: day($0), sport: .run, load: 100) }
        entries += (-6...0).map { LoadEntry(date: day($0), sport: .bike, load: 200) }
        let last = try #require(LoadTrend.days(entries, from: day(0), to: day(0), calendar: calendar).last)
        #expect(last.acute == 200)
        #expect(last.chronic == 125)
        #expect(last.ratio == 1.6)
        #expect(last.isRatioFlagged)
        #expect(last.bySport == [.bike: 200])
    }

    @Test func aWeekOffIsFlaggedTheOtherWay() throws {
        let entries = (-40...(-7)).map { LoadEntry(date: day($0), sport: .run, load: 100) }
        let last = try #require(LoadTrend.days(entries, from: day(0), to: day(0), calendar: calendar).last)
        #expect(last.ratio == 0)
        #expect(last.isRatioFlagged)
    }

    @Test func thereIsNoRatioWithoutAFullChronicWindow() throws {
        let entries = (-10...0).map { LoadEntry(date: day($0), sport: .run, load: 100) }
        let last = try #require(LoadTrend.days(entries, from: day(0), to: day(0), calendar: calendar).last)
        #expect(last.acute == 100)
        #expect(last.ratio == nil)
        #expect(!last.isRatioFlagged)
    }

    @Test func sportsOnOneDayAreKeptApart() throws {
        let entries = [
            LoadEntry(date: day(0).addingTimeInterval(3600), sport: .swim, load: 40),
            LoadEntry(date: day(0).addingTimeInterval(7200), sport: .run, load: 60),
            LoadEntry(date: day(0).addingTimeInterval(9000), sport: .run, load: 20),
        ]
        let last = try #require(LoadTrend.days(entries, from: day(0), to: day(0), calendar: calendar).last)
        #expect(last.bySport == [.swim: 40, .run: 80])
        #expect(last.total == 120)
    }
}

@Suite struct RecoveryBaselineTests {
    let calendar = Calendar(identifier: .gregorian)
    var today: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)) }

    /// Twenty days alternating 58 and 62 (mean 60, SD about 2.05), then one final reading.
    func readings(final: Double) -> [(date: Date, value: Double)] {
        var result = (1...20).map { offset in
            (
                date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                value: offset.isMultiple(of: 2) ? 58.0 : 62.0
            )
        }
        result.append((today, final))
        return result
    }

    @Test func aLowHRVDayIsFlagged() throws {
        let last = try #require(
            RecoveryBaseline.points(readings(final: 55), direction: .lowIsWorse, calendar: calendar).last)
        #expect(last.mean == 60)
        #expect(abs((last.deviation ?? 0) - 2.052) < 0.001)
        #expect(last.isFlagged)
    }

    @Test func onlyTheWrongSideIsFlagged() throws {
        // High HRV is good news; high resting heart rate is not.
        #expect(
            try #require(RecoveryBaseline.points(readings(final: 66), direction: .lowIsWorse, calendar: calendar).last)
                .isFlagged == false)
        #expect(
            try #require(RecoveryBaseline.points(readings(final: 66), direction: .highIsWorse, calendar: calendar).last)
                .isFlagged)
        #expect(
            try #require(RecoveryBaseline.points(readings(final: 55), direction: .highIsWorse, calendar: calendar).last)
                .isFlagged == false)
    }

    @Test func withinOneDeviationIsNormal() throws {
        #expect(
            try #require(
                RecoveryBaseline.points(readings(final: 58.5), direction: .lowIsWorse, calendar: calendar).last
            ).isFlagged == false)
    }

    @Test func thereIsNoBaselineWithTooFewReadings() {
        let few = (0...5).map {
            (date: calendar.date(byAdding: .day, value: -$0, to: today)!, value: $0 == 0 ? 10.0 : 60.0)
        }
        let points = RecoveryBaseline.points(few, direction: .lowIsWorse, calendar: calendar)
        #expect(points.allSatisfy { $0.mean == nil && !$0.isFlagged })
    }

    @Test func readingsOlderThanTheWindowAreIgnored() throws {
        var old = (40...60).map { (date: calendar.date(byAdding: .day, value: -$0, to: today)!, value: 100.0) }
        old.append((today, 50))
        let last = try #require(RecoveryBaseline.points(old, direction: .lowIsWorse, calendar: calendar).last)
        #expect(last.mean == nil)
    }
}
