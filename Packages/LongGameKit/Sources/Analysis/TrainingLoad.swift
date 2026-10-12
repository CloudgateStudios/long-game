import Foundation

public enum HeartRateZones {
    public enum MaxSource: String, Sendable {
        case manual, observed, ageEstimate
    }

    /// The max heart rate to build zones from: a manual value wins, otherwise the higher
    /// of the highest reading seen and the age estimate (an athlete who has only logged
    /// easy sessions has not shown their real max yet).
    public static func maxHeartRate(manual: Double?, observed: Double?, age: Int?) -> (value: Double, source: MaxSource)? {
        if let manual, manual > 0 { return (manual, .manual) }
        let estimate = age.map { AnalysisConstants.maxHRAgeIntercept - AnalysisConstants.maxHRAgeSlope * Double($0) }
        switch (observed, estimate) {
        case let (observed?, estimate?): return observed >= estimate ? (observed, .observed) : (estimate, .ageEstimate)
        case let (observed?, nil): return (observed, .observed)
        case let (nil, estimate?): return (estimate, .ageEstimate)
        case (nil, nil): return nil
        }
    }

    /// Upper bounds of zones 1–4 in bpm, from heart-rate reserve when resting HR is known,
    /// otherwise as fractions of max.
    public static func upperBounds(maxHR: Double, restingHR: Double?) -> [Double] {
        if let restingHR, restingHR > 0, restingHR < maxHR {
            return AnalysisConstants.zoneUpperFractionsOfReserve.map { (restingHR + $0 * (maxHR - restingHR)).rounded() }
        }
        return AnalysisConstants.zoneUpperFractionsOfMax.map { ($0 * maxHR).rounded() }
    }

    /// A manual override wins when it is four ascending values.
    public static func resolve(override: [Double]?, maxHR: Double?, restingHR: Double?) -> [Double]? {
        if let override, isValid(override) { return override }
        return maxHR.map { upperBounds(maxHR: $0, restingHR: restingHR) }
    }

    public static func isValid(_ bounds: [Double]) -> Bool {
        bounds.count == AnalysisConstants.zoneUpperFractionsOfMax.count
            && bounds.allSatisfy { $0 > 0 }
            && zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 }
    }
}

public enum WorkoutLoad {
    public enum Method: String, Sendable {
        /// Zone-weighted minutes from heart rate.
        case heartRate
        /// Average power against FTP (rides only).
        case power
        /// Duration × a default intensity; lower confidence.
        case estimated
    }

    public struct Input: Sendable {
        public var sport: Sport
        public var durationSeconds: Double
        public var heartRateHistogram: [Double]?
        public var averagePowerWatts: Double?
        /// The matched planned session's type, used only for the estimate.
        public var sessionType: SessionType?

        public init(sport: Sport, durationSeconds: Double, heartRateHistogram: [Double]? = nil, averagePowerWatts: Double? = nil, sessionType: SessionType? = nil) {
            self.sport = sport
            self.durationSeconds = durationSeconds
            self.heartRateHistogram = heartRateHistogram
            self.averagePowerWatts = averagePowerWatts
            self.sessionType = sessionType
        }
    }

    public struct Result: Sendable, Equatable {
        public var load: Double
        /// Seconds in zones 1–5, whenever heart rate and zones are both known.
        public var zoneSeconds: [Double]?
        public var method: Method
    }

    public static func compute(_ input: Input, zoneBounds: [Double]?, ftpWatts: Double?) -> Result {
        var zoneSeconds: [Double]?
        if let histogram = input.heartRateHistogram, let zoneBounds, histogram.contains(where: { $0 > 0 }) {
            zoneSeconds = HeartRateHistogram.zoneSeconds(bins: histogram, zoneUpperBounds: zoneBounds)
        }

        if input.sport == .bike, let power = input.averagePowerWatts, power > 0, let ftpWatts, ftpWatts > 0 {
            // Scaled so riding at FTP earns the same per minute as heart rate in zone 4.
            let intensity = power / ftpWatts
            let load = input.durationSeconds / 60 * intensity * intensity * AnalysisConstants.powerLoadPerMinuteAtFTP
            return Result(load: load, zoneSeconds: zoneSeconds, method: .power)
        }
        if let zoneSeconds {
            let load = zip(zoneSeconds, AnalysisConstants.zoneLoadWeights).reduce(0) { $0 + $1.0 / 60 * $1.1 }
            return Result(load: load, zoneSeconds: zoneSeconds, method: .heartRate)
        }
        let intensity = input.sessionType.flatMap { AnalysisConstants.defaultIntensity[$0] } ?? AnalysisConstants.fallbackIntensity
        return Result(load: input.durationSeconds / 60 * intensity, zoneSeconds: nil, method: .estimated)
    }
}

/// One workout's contribution to the load trend.
public struct LoadEntry: Sendable, Equatable {
    public var date: Date
    public var sport: Sport
    public var load: Double

    public init(date: Date, sport: Sport, load: Double) {
        self.date = date
        self.sport = sport
        self.load = load
    }
}

public struct LoadDay: Sendable, Equatable, Identifiable {
    /// Start of the day.
    public var date: Date
    public var total = 0.0
    public var bySport: [Sport: Double] = [:]
    /// Average daily load over the last 7 days, this day included.
    public var acute = 0.0
    /// Average daily load over the last 28 days, this day included.
    public var chronic = 0.0
    /// Acute ÷ chronic. Nil until there are 28 days of history behind it.
    public var ratio: Double?

    public var id: Date { date }

    public var isRatioFlagged: Bool {
        ratio.map { !AnalysisConstants.loadRatioRange.contains($0) } ?? false
    }
}

public enum LoadTrend {
    /// One entry per day from `start` to `end`. Entries before `start` still feed the
    /// rolling averages, so pass history going back further than the days you want.
    public static func days(_ entries: [LoadEntry], from start: Date, to end: Date, calendar: Calendar) -> [LoadDay] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { return [] }

        var totals: [Date: [Sport: Double]] = [:]
        for entry in entries {
            totals[calendar.startOfDay(for: entry.date), default: [:]][entry.sport, default: 0] += entry.load
        }
        let earliest = totals.keys.min()

        func average(endingOn day: Date, days: Int) -> Double {
            var sum = 0.0
            for offset in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: day) else { continue }
                sum += totals[date]?.values.reduce(0, +) ?? 0
            }
            return sum / Double(days)
        }

        var result: [LoadDay] = []
        var day = first
        while day <= last {
            var entry = LoadDay(date: day)
            entry.bySport = totals[day] ?? [:]
            entry.total = entry.bySport.values.reduce(0, +)
            entry.acute = average(endingOn: day, days: AnalysisConstants.acuteLoadDays)
            entry.chronic = average(endingOn: day, days: AnalysisConstants.chronicLoadDays)
            // Without a full chronic window the ratio is inflated and would raise false alarms.
            if let earliest, entry.chronic > 0,
               let windowStart = calendar.date(byAdding: .day, value: -(AnalysisConstants.chronicLoadDays - 1), to: day),
               earliest <= windowStart {
                entry.ratio = entry.acute / entry.chronic
            }
            result.append(entry)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

public enum RecoveryDirection: Sendable {
    /// HRV and sleep: a low reading is the concern.
    case lowIsWorse
    /// Resting heart rate: a high reading is the concern.
    case highIsWorse
}

public struct BaselinePoint: Sendable, Equatable, Identifiable {
    public var date: Date
    public var value: Double
    /// Mean and standard deviation of the preceding 28 days; nil with too little history.
    public var mean: Double?
    public var deviation: Double?
    public var isFlagged = false

    public var id: Date { date }
}

public enum RecoveryBaseline {
    /// Each reading against the rolling baseline of the days before it.
    public static func points(_ readings: [(date: Date, value: Double)], direction: RecoveryDirection, calendar: Calendar) -> [BaselinePoint] {
        let sorted = readings.sorted { $0.date < $1.date }
        return sorted.map { reading in
            var point = BaselinePoint(date: reading.date, value: reading.value)
            guard let windowStart = calendar.date(byAdding: .day, value: -AnalysisConstants.baselineDays, to: reading.date) else { return point }
            let window = sorted.filter { $0.date >= windowStart && $0.date < reading.date }.map(\.value)
            guard window.count >= AnalysisConstants.baselineMinimumReadings else { return point }

            let mean = window.reduce(0, +) / Double(window.count)
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count - 1)
            let deviation = variance.squareRoot()
            point.mean = mean
            point.deviation = deviation
            let threshold = AnalysisConstants.baselineFlagStandardDeviations * deviation
            if deviation > 0 {
                switch direction {
                case .lowIsWorse: point.isFlagged = reading.value < mean - threshold
                case .highIsWorse: point.isFlagged = reading.value > mean + threshold
                }
            }
            return point
        }
    }
}
