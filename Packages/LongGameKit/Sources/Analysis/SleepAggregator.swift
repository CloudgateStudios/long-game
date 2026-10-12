import Foundation

public enum SleepStage: String, Codable, Sendable {
    case inBed, core, deep, rem, unspecified, awake

    var isAsleep: Bool {
        switch self {
        case .core, .deep, .rem, .unspecified: true
        case .inBed, .awake: false
        }
    }
}

public struct SleepSegment: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage

    public init(start: Date, end: Date, stage: SleepStage) {
        self.start = start
        self.end = end
        self.stage = stage
    }
}

public struct SleepSummary: Sendable, Equatable {
    /// Total time asleep, counting overlapping segments from two sources once.
    public var asleepSeconds = 0.0
    public var coreSeconds = 0.0
    public var deepSeconds = 0.0
    public var remSeconds = 0.0
    public var awakeSeconds = 0.0
}

public enum SleepAggregator {
    /// Sleep per day, keyed by the start of the day the night belongs to: a segment that
    /// starts in the evening counts toward the next morning.
    public static func summarize(_ segments: [SleepSegment], calendar: Calendar) -> [Date: SleepSummary] {
        let shift = AnalysisConstants.sleepDayShiftHours * 3600
        let byDay = Dictionary(grouping: segments.filter { $0.end > $0.start }) {
            calendar.startOfDay(for: $0.start.addingTimeInterval(shift))
        }
        return byDay.mapValues { segments in
            var summary = SleepSummary()
            for segment in segments {
                let seconds = segment.end.timeIntervalSince(segment.start)
                switch segment.stage {
                case .core: summary.coreSeconds += seconds
                case .deep: summary.deepSeconds += seconds
                case .rem: summary.remSeconds += seconds
                case .awake: summary.awakeSeconds += seconds
                case .inBed, .unspecified: break
                }
            }
            summary.asleepSeconds = unionLength(segments.filter(\.stage.isAsleep))
            return summary
        }
    }

    private static func unionLength(_ segments: [SleepSegment]) -> Double {
        var total = 0.0
        var current: (start: Date, end: Date)?
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let open = current, segment.start <= open.end {
                current = (open.start, max(open.end, segment.end))
            } else {
                if let open = current { total += open.end.timeIntervalSince(open.start) }
                current = (segment.start, segment.end)
            }
        }
        if let open = current { total += open.end.timeIntervalSince(open.start) }
        return total
    }
}
