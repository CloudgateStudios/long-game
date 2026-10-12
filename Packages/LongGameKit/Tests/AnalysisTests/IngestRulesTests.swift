import Analysis
import Foundation
import Testing

@Suite struct HeartRateHistogramTests {
    @Test func noSamplesMeansNoSummary() {
        #expect(HeartRateHistogram.summarize([], duration: 600) == nil)
    }

    @Test func averageIsWeightedByTime() throws {
        // 100 bpm for 60 s, then 160 bpm for 30 s.
        let points = [HeartRatePoint(offset: 0, bpm: 100), HeartRatePoint(offset: 60, bpm: 160)]
        let summary = try #require(HeartRateHistogram.summarize(points, duration: 90))
        #expect(abs(summary.average - 120) < 0.001)
        #expect(summary.max == 160)
        #expect(summary.bins.reduce(0, +) == 90)
        #expect(summary.bins[14] == 60) // 100–104 bpm
        #expect(summary.bins[26] == 30) // 160–164 bpm
    }

    @Test func longGapsAreCapped() throws {
        let points = [HeartRatePoint(offset: 0, bpm: 120), HeartRatePoint(offset: 900, bpm: 120)]
        let summary = try #require(HeartRateHistogram.summarize(points, duration: 960))
        #expect(summary.bins.reduce(0, +) == AnalysisConstants.heartRateMaxGapSeconds + 60)
    }

    @Test func outOfRangeReadingsLandInTheEndBins() throws {
        let points = [HeartRatePoint(offset: 0, bpm: 20), HeartRatePoint(offset: 10, bpm: 260)]
        let summary = try #require(HeartRateHistogram.summarize(points, duration: 20))
        #expect(summary.bins.first == 10)
        #expect(summary.bins.last == 10)
    }

    @Test func binsSplitIntoZones() {
        var bins = Array(repeating: 0.0, count: AnalysisConstants.histogramBinCount)
        bins[14] = 600 // 100–104
        bins[22] = 300 // 140–144
        bins[30] = 120 // 180–184
        let zones = HeartRateHistogram.zoneSeconds(bins: bins, zoneUpperBounds: [114, 133, 152, 171])
        #expect(zones == [600, 0, 300, 0, 120])
    }
}

@Suite struct DuplicateResolverTests {
    let base = Date(timeIntervalSince1970: 1_790_000_000)

    func candidate(_ sport: Sport = .bike, at minutes: Double = 0, for duration: Double = 120,
                   power: Bool = false, hr: Bool = false, fit: Bool = false, manual: Bool = false) -> SessionCandidate {
        SessionCandidate(id: UUID(), sport: sport, start: base.addingTimeInterval(minutes * 60), duration: duration * 60,
                         hasPower: power, hasHeartRate: hr, isFITImport: fit, isManualPrimary: manual)
    }

    @Test func aRideRecordedTwiceCountsOnce() {
        let watch = candidate(hr: true)
        let wahoo = candidate(at: 1, for: 118, power: true)
        let result = DuplicateResolver.resolve([watch, wahoo])
        #expect(result[wahoo.id] == true) // power wins for cycling
        #expect(result[watch.id] == false)
    }

    @Test func heartRateWinsWhenNeitherHasPower() {
        let withHR = candidate(.run, hr: true)
        let summaryOnly = candidate(.run, at: 1)
        let result = DuplicateResolver.resolve([summaryOnly, withHR])
        #expect(result[withHR.id] == true)
        #expect(result[summaryOnly.id] == false)
    }

    @Test func powerDoesNotDecideARun() {
        let withPower = candidate(.run, power: true)
        let withHR = candidate(.run, at: 1, hr: true)
        #expect(DuplicateResolver.resolve([withPower, withHR])[withHR.id] == true)
    }

    @Test func differentSportsAreNeverDuplicates() {
        let ride = candidate(.bike)
        let run = candidate(.run)
        #expect(DuplicateResolver.resolve([ride, run]) == [ride.id: true, run.id: true])
    }

    @Test func aShortWorkoutInsideALongOneIsSeparate() {
        let long = candidate(for: 120)
        let short = candidate(at: 30, for: 30)
        #expect(DuplicateResolver.overlapFraction(long, short) == 0.25)
        #expect(DuplicateResolver.resolve([long, short]) == [long.id: true, short.id: true])
    }

    @Test func overlapMustExceedTheThreshold() {
        let first = candidate(for: 100)
        let justUnder = candidate(at: 30, for: 100) // 70% shared
        let over = candidate(at: 29, for: 100) // 71% shared
        #expect(!DuplicateResolver.isSameSession(first, justUnder))
        #expect(DuplicateResolver.isSameSession(first, over))
    }

    @Test func aManualChoiceBeatsEverything() {
        let chosen = candidate(manual: true)
        let fit = candidate(at: 1, power: true, hr: true, fit: true)
        let result = DuplicateResolver.resolve([chosen, fit])
        #expect(result[chosen.id] == true)
        #expect(result[fit.id] == false)
    }

    @Test func aFITImportBeatsTheHealthRecord() {
        let health = candidate(power: true, hr: true)
        let fit = candidate(at: 1, fit: true)
        #expect(DuplicateResolver.resolve([health, fit])[fit.id] == true)
    }

    @Test func threeRecordingsLeaveOnePrimary() {
        let all = [candidate(hr: true), candidate(at: 1, power: true), candidate(at: 2)]
        #expect(DuplicateResolver.resolve(all).values.filter { $0 }.count == 1)
        #expect(DuplicateResolver.groups(all).count == 1)
    }
}

@Suite struct SleepAggregatorTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func aNightBelongsToTheDayItEnds() throws {
        let segments = [
            SleepSegment(start: time(10, 22, 30), end: time(11, 1), stage: .core),
            SleepSegment(start: time(11, 1), end: time(11, 2), stage: .deep),
            SleepSegment(start: time(11, 2), end: time(11, 2, 15), stage: .awake),
            SleepSegment(start: time(11, 2, 15), end: time(11, 6), stage: .rem),
        ]
        let result = SleepAggregator.summarize(segments, calendar: calendar)
        #expect(result.count == 1)
        let night = try #require(result[calendar.startOfDay(for: time(11, 12))])
        #expect(night.coreSeconds == 2.5 * 3600)
        #expect(night.deepSeconds == 3600)
        #expect(night.remSeconds == 3.75 * 3600)
        #expect(night.awakeSeconds == 900)
        #expect(night.asleepSeconds == 7.25 * 3600)
    }

    @Test func anAfternoonNapStaysOnItsOwnDay() {
        let nap = SleepSegment(start: time(11, 14), end: time(11, 14, 40), stage: .unspecified)
        let result = SleepAggregator.summarize([nap], calendar: calendar)
        #expect(result[calendar.startOfDay(for: time(11, 12))]?.asleepSeconds == 2400)
    }

    @Test func overlappingSourcesAreCountedOnce() {
        let segments = [
            SleepSegment(start: time(11, 0), end: time(11, 6), stage: .unspecified),
            SleepSegment(start: time(11, 1), end: time(11, 7), stage: .core),
            SleepSegment(start: time(10, 23), end: time(11, 7, 30), stage: .inBed),
        ]
        let result = SleepAggregator.summarize(segments, calendar: calendar)
        #expect(result[calendar.startOfDay(for: time(11, 12))]?.asleepSeconds == 25_200.0)
    }
}
