import Foundation

/// A calendar day with no time zone attached, stored as midnight UTC of that year, month
/// and day. A planned session or a night's sleep belongs to a day, not an instant: stored
/// as local midnight it would slide onto the neighbouring day whenever the device changed
/// time zone, and the same day would stop comparing equal to itself.
public enum CalendarDay {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// The stamp for the day `date` falls on in `calendar`.
    public static func stamp(for date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return utc.date(from: day) ?? date
    }

    /// The start of the stamped day in `calendar`, for display and day arithmetic.
    public static func date(for stamp: Date, calendar: Calendar = .current) -> Date {
        var day = utc.dateComponents([.year, .month, .day], from: stamp)
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        return calendar.date(from: day).map { calendar.startOfDay(for: $0) } ?? stamp
    }

    public static func isStamp(_ date: Date) -> Bool {
        date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0
    }
}
