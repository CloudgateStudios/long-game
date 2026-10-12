import Foundation

public struct HeartRatePoint: Codable, Sendable, Equatable {
    /// Seconds from the workout start.
    public var offset: Double
    public var bpm: Double

    public init(offset: Double, bpm: Double) {
        self.offset = offset
        self.bpm = bpm
    }
}

/// Time spent at each heart rate, in fixed-width bins. Stored with a workout instead of
/// the raw samples: it is small, and zones can be recomputed from it on any device
/// whenever the zone boundaries change.
public enum HeartRateHistogram {
    public struct Summary: Equatable, Sendable {
        /// Seconds per bin; bin 0 starts at `AnalysisConstants.histogramLowestBPM`.
        public var bins: [Double]
        /// Time-weighted average.
        public var average: Double
        public var max: Double
    }

    /// Each sample counts until the next one, capped so a pause or a dropped strap does
    /// not stretch one reading across minutes. Nil when there are no samples.
    public static func summarize(_ points: [HeartRatePoint], duration: Double) -> Summary? {
        let sorted = points.filter { $0.bpm > 0 }.sorted { $0.offset < $1.offset }
        guard !sorted.isEmpty else { return nil }
        let cap = AnalysisConstants.heartRateMaxGapSeconds

        var bins = Array(repeating: 0.0, count: AnalysisConstants.histogramBinCount)
        var weighted = 0.0
        var total = 0.0
        for (index, point) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1].offset : Swift.max(duration, point.offset)
            // A lone or final sample still counts for a moment.
            let seconds = Swift.max(1, Swift.min(next - point.offset, cap))
            bins[binIndex(for: point.bpm)] += seconds
            weighted += point.bpm * seconds
            total += seconds
        }
        return Summary(bins: bins, average: weighted / total, max: sorted.map(\.bpm).max() ?? 0)
    }

    /// Seconds in each zone. `zoneUpperBounds` holds the top of zones 1…n-1 in bpm; a bin
    /// is assigned by its midpoint, and everything above the last bound is the top zone.
    public static func zoneSeconds(bins: [Double], zoneUpperBounds: [Double]) -> [Double] {
        var zones = Array(repeating: 0.0, count: zoneUpperBounds.count + 1)
        for (index, seconds) in bins.enumerated() where seconds > 0 {
            let midpoint = AnalysisConstants.histogramLowestBPM + (Double(index) + 0.5) * AnalysisConstants.histogramBinWidth
            let zone = zoneUpperBounds.firstIndex { midpoint <= $0 } ?? zoneUpperBounds.count
            zones[zone] += seconds
        }
        return zones
    }

    static func binIndex(for bpm: Double) -> Int {
        let raw = Int(((bpm - AnalysisConstants.histogramLowestBPM) / AnalysisConstants.histogramBinWidth).rounded(.down))
        return Swift.min(Swift.max(raw, 0), AnalysisConstants.histogramBinCount - 1)
    }
}
