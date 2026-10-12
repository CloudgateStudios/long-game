import Foundation

/// One billed API call, as the spending summary sees it.
public struct SpendEntry: Sendable, Equatable {
    public var date: Date
    public var cost: Double
    /// The review, plan generation or conversation the call belonged to.
    public var sessionID: UUID

    public init(date: Date, cost: Double, sessionID: UUID) {
        self.date = date
        self.cost = cost
        self.sessionID = sessionID
    }
}

public struct SpendSummary: Sendable, Equatable {
    public var total = 0.0
    /// The calendar month containing `now`.
    public var thisMonth = 0.0
    /// The week containing `now`, Sunday through Saturday.
    public var thisWeek = 0.0
    /// A coaching session is one review, one plan generation, or one whole conversation.
    public var sessions = 0

    public var averagePerSession: Double? {
        sessions > 0 ? total / Double(sessions) : nil
    }

    public init(_ entries: [SpendEntry], now: Date, calendar: Calendar) {
        // Weeks run Sunday to Saturday whatever the device's own first weekday is.
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let month = calendar.dateInterval(of: .month, for: now)
        let week = sundayFirst.dateInterval(of: .weekOfYear, for: now)
        for entry in entries {
            total += entry.cost
            if let month, month.start <= entry.date, entry.date < month.end { thisMonth += entry.cost }
            if let week, week.start <= entry.date, entry.date < week.end { thisWeek += entry.cost }
        }
        sessions = Set(entries.map(\.sessionID)).count
    }
}
