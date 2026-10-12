import Analysis
import Foundation
import Testing

@Suite struct PlanCalendarTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 15))!
    }

    func ymd(_ date: Date) -> [Int] {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return [parts.year!, parts.month!, parts.day!]
    }

    @Test func weekStartsOnTheCalendarsFirstWeekday() {
        // 14 October 2026 is a Wednesday.
        let days = PlanCalendar.weekDays(containing: day(2026, 10, 14), calendar: calendar)
        #expect(days.count == 7)
        #expect(ymd(days[0]) == [2026, 10, 12])
        #expect(ymd(days[6]) == [2026, 10, 18])

        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        #expect(ymd(PlanCalendar.weekDays(containing: day(2026, 10, 14), calendar: sundayFirst)[0]) == [2026, 10, 11])
    }

    @Test func weekSpansADaylightSavingChange() {
        // Clocks go back on 1 November 2026 in the US.
        let days = PlanCalendar.weekDays(containing: day(2026, 10, 30), calendar: calendar)
        #expect(days.map { calendar.component(.day, from: $0) } == [26, 27, 28, 29, 30, 31, 1])
    }

    @Test func monthGridPadsToWholeWeeks() {
        // October 2026 starts on a Thursday and has 31 days.
        let grid = PlanCalendar.monthGrid(containing: day(2026, 10, 14), calendar: calendar)
        #expect(grid.count == 35)
        #expect(grid.prefix(3).allSatisfy { $0 == nil })
        #expect(ymd(grid[3]!) == [2026, 10, 1])
        #expect(grid.compactMap { $0 }.count == 31)
        #expect(grid.last! == nil)
    }

    @Test func monthGridHandlesAMonthThatFillsItsRowsExactly() {
        // February 2027 starts on a Monday and has 28 days.
        let grid = PlanCalendar.monthGrid(containing: day(2027, 2, 10), calendar: calendar)
        #expect(grid.count == 28)
        #expect(grid.allSatisfy { $0 != nil })
    }

    @Test func weekdaySymbolsFollowFirstWeekday() {
        #expect(PlanCalendar.weekdaySymbols(calendar: calendar).count == 7)
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        #expect(PlanCalendar.weekdaySymbols(calendar: calendar).last == PlanCalendar.weekdaySymbols(calendar: sundayFirst).first)
    }

    @Test func suggestedPhasesCoverThePlanWithoutGaps() {
        // 13 weeks: 12 October 2026 to 10 January 2027.
        let phases = PhaseTemplate.suggest(start: day(2026, 10, 12), end: day(2027, 1, 10), calendar: calendar)
        #expect(phases.map(\.kind) == [.base, .build, .peak, .taper])
        #expect(ymd(phases.first!.start) == [2026, 10, 12])
        #expect(ymd(phases.last!.end) == [2027, 1, 10])
        for (previous, next) in zip(phases, phases.dropFirst()) {
            #expect(calendar.date(byAdding: .day, value: 1, to: previous.end) == next.start)
        }
        // Two-week taper ends on race day, preceded by a two-week peak.
        #expect(ymd(phases[3].start) == [2026, 12, 28])
        #expect(ymd(phases[2].start) == [2026, 12, 14])
    }

    @Test func shortPlansKeepTheTaper() {
        let phases = PhaseTemplate.suggest(start: day(2026, 12, 21), end: day(2027, 1, 10), calendar: calendar)
        #expect(phases.map(\.kind) == [.peak, .taper])
        #expect(ymd(phases[0].start) == [2026, 12, 21])
        #expect(ymd(phases[1].end) == [2027, 1, 10])
    }

    @Test func aPlanEndingBeforeItStartsHasNoPhases() {
        #expect(PhaseTemplate.suggest(start: day(2027, 1, 10), end: day(2026, 10, 12), calendar: calendar).isEmpty)
    }
}
