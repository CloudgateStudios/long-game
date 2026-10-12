import Analysis
import Foundation
import Testing

@Suite struct CalendarDayTests {
    func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func aDayKeepsItsDateWhenTheTimeZoneChanges() throws {
        let chicago = calendar("America/Chicago")
        let tokyo = calendar("Asia/Tokyo")
        // Planned at 9 pm on 14 October in Chicago, which is already the 15th in Tokyo.
        let planned = try #require(
            DateComponents(calendar: chicago, year: 2026, month: 10, day: 14, hour: 21).date)
        let stamp = CalendarDay.stamp(for: planned, calendar: chicago)

        for reader in [chicago, tokyo, calendar("Pacific/Auckland"), calendar("Pacific/Honolulu")] {
            let shown = CalendarDay.date(for: stamp, calendar: reader)
            #expect(
                reader.dateComponents([.year, .month, .day], from: shown)
                    == DateComponents(year: 2026, month: 10, day: 14))
            #expect(shown == reader.startOfDay(for: shown))
            // Reading and writing back in any zone leaves the stored value alone.
            #expect(CalendarDay.stamp(for: shown, calendar: reader) == stamp)
        }
    }

    @Test func theSameDayAlwaysHasTheSameStamp() throws {
        let chicago = calendar("America/Chicago")
        let morning = try #require(DateComponents(calendar: chicago, year: 2026, month: 3, day: 8, hour: 1).date)
        let night = try #require(DateComponents(calendar: chicago, year: 2026, month: 3, day: 8, hour: 23).date)
        // The clocks go forward that day; it is still one day.
        #expect(CalendarDay.stamp(for: morning, calendar: chicago) == CalendarDay.stamp(for: night, calendar: chicago))
        let next = try #require(chicago.date(byAdding: .day, value: 1, to: morning))
        #expect(
            CalendarDay.stamp(for: next, calendar: chicago).timeIntervalSince(
                CalendarDay.stamp(for: morning, calendar: chicago)) == 86_400)
    }

    @Test func stampsAreRecognisable() throws {
        let chicago = calendar("America/Chicago")
        let midnight = try #require(DateComponents(calendar: chicago, year: 2026, month: 10, day: 14).date)
        #expect(!CalendarDay.isStamp(midnight))
        #expect(CalendarDay.isStamp(CalendarDay.stamp(for: midnight, calendar: chicago)))
    }
}
