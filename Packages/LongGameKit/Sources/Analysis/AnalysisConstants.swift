import Foundation

/// Every tunable threshold used by the analysis rules lives here.
public enum AnalysisConstants {
    // MARK: Ingest

    public static let backfillDays = 90
    /// Two same-sport workouts overlapping by more than this fraction are one session.
    public static let duplicateOverlapFraction = 0.7
    /// Later syncs re-read this many days of daily metrics, since sleep and HRV can arrive late.
    public static let dailyMetricsLookbackDays = 3
    /// Sleep that starts within this many hours of midnight counts toward the next day.
    public static let sleepDayShiftHours = 6.0

    // MARK: Heart-rate histogram

    public static let histogramLowestBPM = 30.0
    public static let histogramBinWidth = 5.0
    public static let histogramBinCount = 40
    /// The longest a single heart-rate sample is allowed to stand for.
    public static let heartRateMaxGapSeconds = 120.0

    // MARK: Plan

    /// Phase lengths used when suggesting a split for a new plan.
    public static let taperWeeks = 2
    public static let peakWeeks = 2

    // MARK: Zones

    /// Upper bound of zones 1–4 as a fraction of max HR (zone 5 is everything above).
    public static let zoneUpperFractionsOfMax: [Double] = [0.60, 0.70, 0.80, 0.90]
    /// Upper bound of zones 1–4 as a fraction of heart-rate reserve.
    public static let zoneUpperFractionsOfReserve: [Double] = [0.60, 0.70, 0.80, 0.90]

    /// Max heart rate estimated from age: intercept − slope × age (Tanaka).
    public static let maxHRAgeIntercept = 208.0
    public static let maxHRAgeSlope = 0.7

    // MARK: Load

    /// Load points per minute for a ride at exactly FTP; matches the zone 4 weight.
    public static let powerLoadPerMinuteAtFTP = 4.0

    /// Load points per minute spent in zones 1–5.
    public static let zoneLoadWeights: [Double] = [1, 2, 3, 4, 5]
    /// Load points per minute assumed for a session type when there is no heart rate
    /// or power to measure it. On the same scale as `zoneLoadWeights`.
    public static let defaultIntensity: [SessionType: Double] = [
        .recovery: 1.5, .easy: 2, .long: 2, .tempo: 3.5, .intervals: 4, .race: 4, .strength: 2, .other: 2, .rest: 0,
        .flex: 0,
    ]
    public static let fallbackIntensity = 2.0
    public static let acuteLoadDays = 7
    public static let chronicLoadDays = 28
    public static let loadRatioRange: ClosedRange<Double> = 0.8...1.3

    // MARK: Recovery

    public static let baselineDays = 28
    public static let baselineFlagStandardDeviations = 1.0
    /// Fewer readings than this in the window and there is no baseline to compare against.
    public static let baselineMinimumReadings = 10

    // MARK: Matching and compliance

    public static let matchDayTolerance = 1
    public static let partialRange: Range<Double> = 0.5..<0.8
    public static let doneRange: ClosedRange<Double> = 0.8...1.2
}
