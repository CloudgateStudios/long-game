import Foundation

/// What the resolver needs to know about one recorded workout.
public struct SessionCandidate: Sendable, Equatable {
    public var id: UUID
    public var sport: Sport
    public var start: Date
    public var duration: Double
    public var hasPower: Bool
    public var hasHeartRate: Bool
    public var isFITImport: Bool
    /// The user picked this record to be the one that counts.
    public var isManualPrimary: Bool

    public init(
        id: UUID,
        sport: Sport,
        start: Date,
        duration: Double,
        hasPower: Bool = false,
        hasHeartRate: Bool = false,
        isFITImport: Bool = false,
        isManualPrimary: Bool = false
    ) {
        self.id = id
        self.sport = sport
        self.start = start
        self.duration = duration
        self.hasPower = hasPower
        self.hasHeartRate = hasHeartRate
        self.isFITImport = isFITImport
        self.isManualPrimary = isManualPrimary
    }

    var end: Date { start.addingTimeInterval(duration) }
}

/// The same session recorded by two devices (say a watch and a bike computer) is kept as
/// two records, with exactly one marked primary and counted toward load and matching.
public enum DuplicateResolver {
    /// Shared time as a fraction of the longer workout, so a short workout inside a long
    /// one is not treated as the same session.
    public static func overlapFraction(_ a: SessionCandidate, _ b: SessionCandidate) -> Double {
        let longer = max(a.duration, b.duration)
        guard longer > 0 else { return 0 }
        let shared = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        return max(0, shared) / longer
    }

    public static func isSameSession(_ a: SessionCandidate, _ b: SessionCandidate) -> Bool {
        a.id != b.id && a.sport == b.sport && overlapFraction(a, b) > AnalysisConstants.duplicateOverlapFraction
    }

    /// Groups of records that are the same session, each ordered best first. Records
    /// with no duplicate come back as groups of one.
    public static func groups(_ candidates: [SessionCandidate]) -> [[SessionCandidate]] {
        let sorted = candidates.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        var parent = Array(sorted.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for i in sorted.indices {
            for j in sorted.indices.dropFirst(i + 1) {
                if sorted[j].start >= sorted[i].end { break }
                if isSameSession(sorted[i], sorted[j]) { parent[root(j)] = root(i) }
            }
        }
        var byRoot: [Int: [SessionCandidate]] = [:]
        for index in sorted.indices {
            byRoot[root(index), default: []].append(sorted[index])
        }
        return byRoot.keys.sorted().map { byRoot[$0]!.sorted(by: isBetter) }
    }

    /// Whether each record is the primary one for its session.
    public static func resolve(_ candidates: [SessionCandidate]) -> [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for group in groups(candidates) {
            for (index, candidate) in group.enumerated() {
                result[candidate.id] = index == 0
            }
        }
        return result
    }

    /// A manual choice wins, then a FIT import, then power for rides, then heart-rate
    /// samples, then the longer recording.
    static func isBetter(_ a: SessionCandidate, _ b: SessionCandidate) -> Bool {
        func rank(_ c: SessionCandidate) -> [Int] {
            [
                c.isManualPrimary ? 1 : 0,
                c.isFITImport ? 1 : 0,
                c.sport == .bike && c.hasPower ? 1 : 0,
                c.hasHeartRate ? 1 : 0,
            ]
        }
        let (rankA, rankB) = (rank(a), rank(b))
        if rankA != rankB { return rankA.lexicographicallyPrecedes(rankB) == false }
        if a.duration != b.duration { return a.duration > b.duration }
        return (a.start, a.id.uuidString) < (b.start, b.id.uuidString)
    }
}
