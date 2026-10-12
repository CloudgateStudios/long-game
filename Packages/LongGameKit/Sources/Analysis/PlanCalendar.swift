import Foundation

/// Date arithmetic for the plan's week and month views.
public enum PlanCalendar {
    /// The seven days of the week containing `date`, starting on the calendar's first weekday.
    public static func weekDays(containing date: Date, calendar: Calendar) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// The days of the month containing `date` laid out in rows of seven. Cells before
    /// the first and after the last day of the month are nil.
    public static func monthGrid(containing date: Date, calendar: Calendar) -> [Date?] {
        guard let month = calendar.dateInterval(of: .month, for: date),
            let dayCount = calendar.range(of: .day, in: .month, for: date)?.count
        else { return [] }
        let weekday = calendar.component(.weekday, from: month.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        cells += (0..<dayCount).map { calendar.date(byAdding: .day, value: $0, to: month.start) }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return cells
    }

    /// Weekday symbols ordered to match `weekDays` and `monthGrid`.
    public static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}

public struct SuggestedPhase: Equatable, Sendable {
    public var kind: PlanPhaseKind
    public var start: Date
    /// Last day of the phase (inclusive).
    public var end: Date
}

public enum PhaseTemplate {
    /// A starting split of a plan into base, build, peak and taper, in whole weeks
    /// counted back from the end date. Short plans drop the earliest phases first.
    public static func suggest(start: Date, end: Date, calendar: Calendar) -> [SuggestedPhase] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard let totalDays = calendar.dateComponents([.day], from: first, to: last).day, totalDays >= 0 else {
            return []
        }
        let weeks = max(1, (totalDays + 1) / 7)

        let taper = min(AnalysisConstants.taperWeeks, weeks)
        let peak = min(AnalysisConstants.peakWeeks, weeks - taper)
        let remaining = weeks - taper - peak
        let build = remaining / 2
        let base = remaining - build

        // Days that do not fill a whole week go to the first phase.
        var phases: [SuggestedPhase] = []
        var cursor = first
        let lengths: [(PlanPhaseKind, Int)] = [(.base, base), (.build, build), (.peak, peak), (.taper, taper)]
        let used = lengths.filter { $0.1 > 0 }
        for (index, (kind, length)) in used.enumerated() {
            let isLast = index == used.count - 1
            let extra = index == 0 ? (totalDays + 1) - weeks * 7 : 0
            let phaseEnd =
                isLast
                ? last
                : calendar.date(byAdding: .day, value: length * 7 + extra - 1, to: cursor) ?? last
            phases.append(SuggestedPhase(kind: kind, start: cursor, end: phaseEnd))
            cursor = calendar.date(byAdding: .day, value: 1, to: phaseEnd) ?? last
        }
        return phases
    }
}
