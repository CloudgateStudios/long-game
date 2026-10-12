import Analysis
import Foundation
import Testing

@Suite struct DomainTests {
    @Test func enduranceSportsAreSwimBikeRun() {
        #expect(Sport.allCases.filter(\.isEndurance) == [.swim, .bike, .run])
    }

    @Test func goalPrioritiesSortAFirst() {
        #expect([GoalPriority.c, .a, .b].sorted() == [.a, .b, .c])
    }

    @Test func complianceRangesDoNotOverlap() {
        #expect(AnalysisConstants.partialRange.upperBound == AnalysisConstants.doneRange.lowerBound)
        #expect(!AnalysisConstants.partialRange.contains(AnalysisConstants.doneRange.lowerBound))
    }

    @Test func zoneTablesDescribeFiveZones() {
        #expect(AnalysisConstants.zoneUpperFractionsOfMax.count == 4)
        #expect(AnalysisConstants.zoneUpperFractionsOfReserve.count == 4)
        #expect(AnalysisConstants.zoneLoadWeights.count == 5)
    }
}

@Suite struct SpendSummaryTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 2 // a Monday-first device must still get Sunday-to-Saturday weeks
        return calendar
    }

    func time(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func splitsSpendByMonthAndSundayToSaturdayWeek() {
        let chat = UUID()
        let entries = [
            SpendEntry(date: time(9, 30), cost: 1.00, sessionID: UUID()), // last month
            SpendEntry(date: time(10, 3), cost: 0.50, sessionID: UUID()), // this month, earlier week
            SpendEntry(date: time(10, 10, 23), cost: 0.25, sessionID: UUID()), // Saturday night: last week
            SpendEntry(date: time(10, 11, 0), cost: 0.20, sessionID: chat), // Sunday 00:00: this week
            SpendEntry(date: time(10, 14), cost: 0.05, sessionID: chat), // same conversation, later turn
        ]
        // Wednesday 14 October 2026.
        let summary = SpendSummary(entries, now: time(10, 14, 18), calendar: calendar)
        #expect(abs(summary.total - 2.00) < 1e-9)
        #expect(abs(summary.thisMonth - 1.00) < 1e-9)
        #expect(abs(summary.thisWeek - 0.25) < 1e-9)
        // Two turns of one conversation are one session.
        #expect(summary.sessions == 4)
        #expect(abs((summary.averagePerSession ?? 0) - 0.50) < 1e-9)
    }

    @Test func aWeekCanStraddleTwoMonths() {
        // Sunday 27 September to Saturday 3 October; today is Thursday 1 October.
        let entries = [SpendEntry(date: time(9, 28), cost: 0.4, sessionID: UUID()), SpendEntry(date: time(10, 1), cost: 0.1, sessionID: UUID())]
        let summary = SpendSummary(entries, now: time(10, 1, 20), calendar: calendar)
        #expect(abs(summary.thisWeek - 0.5) < 1e-9)
        #expect(abs(summary.thisMonth - 0.1) < 1e-9)
    }

    @Test func nothingSpentHasNoAverage() {
        let summary = SpendSummary([], now: time(10, 14), calendar: calendar)
        #expect(summary.total == 0)
        #expect(summary.averagePerSession == nil)
    }
}
