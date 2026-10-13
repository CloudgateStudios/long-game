import Foundation

/// A planned session as the matching and compliance rules see it.
public struct PlannedSession: Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var sport: Sport
    /// What an "other" session is, when the athlete named it.
    public var activity: String?
    public var sessionType: SessionType
    public var targetDurationSeconds: Double?
    public var targetDistanceMeters: Double?

    public init(
        id: UUID,
        date: Date,
        sport: Sport,
        activity: String? = nil,
        sessionType: SessionType = .easy,
        targetDurationSeconds: Double? = nil,
        targetDistanceMeters: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.sport = sport
        self.activity = activity
        self.sessionType = sessionType
        self.targetDurationSeconds = targetDurationSeconds
        self.targetDistanceMeters = targetDistanceMeters
    }
}

public struct CompletedSession: Sendable, Equatable {
    public var id: UUID
    public var start: Date
    public var sport: Sport
    /// The activity as recorded, for an "other" workout.
    public var activity: String?
    public var durationSeconds: Double
    public var distanceMeters: Double?
    /// Measured training load, when it has been computed.
    public var load: Double?

    public init(
        id: UUID, start: Date, sport: Sport, activity: String? = nil, durationSeconds: Double,
        distanceMeters: Double? = nil, load: Double? = nil
    ) {
        self.id = id
        self.start = start
        self.sport = sport
        self.activity = activity
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.load = load
    }
}

public enum PlanMatcher {
    /// Pairs planned sessions with completed workouts, one to one: same sport on the
    /// same day first, then within `matchDayTolerance` days. Returns planned ID → completed ID.
    /// A session that names its activity ("Hiking") is not paired with a workout recorded
    /// under another name.
    ///
    /// Pass only what may be matched automatically: no rest or flex days, no duplicates, and
    /// nothing the user has matched or un-matched by hand.
    public static func match(planned: [PlannedSession], completed: [CompletedSession], calendar: Calendar) -> [UUID:
        UUID]
    {
        let ordered = planned.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        var available = completed
        var result: [UUID: UUID] = [:]

        func dayDistance(_ session: PlannedSession, _ workout: CompletedSession) -> Int {
            let days =
                calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: session.date), to: calendar.startOfDay(for: workout.start)
                ).day ?? .max
            return abs(days)
        }

        func take(for session: PlannedSession, maxDays: Int) {
            let candidates = available.filter {
                $0.sport == session.sport && ActivityName.agree(session.activity, $0.activity)
                    && dayDistance(session, $0) <= maxDays
            }
            // Nearest day wins, then whichever is closest to the target, then the earliest.
            let best = candidates.min { a, b in
                let keyA = (dayDistance(session, a), fit(session, a), a.start, a.id.uuidString)
                let keyB = (dayDistance(session, b), fit(session, b), b.start, b.id.uuidString)
                return keyA < keyB
            }
            guard let best else { return }
            result[session.id] = best.id
            available.removeAll { $0.id == best.id }
        }

        // Every same-day match is settled before any session reaches into a neighbouring day.
        for session in ordered {
            take(for: session, maxDays: 0)
        }
        for session in ordered where result[session.id] == nil {
            take(for: session, maxDays: AnalysisConstants.matchDayTolerance)
        }
        return result
    }

    /// How far a workout is from the session's target; zero is a perfect fit or no target.
    private static func fit(_ session: PlannedSession, _ workout: CompletedSession) -> Double {
        guard let ratio = Compliance.ratio(planned: session, completed: workout), ratio > 0 else { return 0 }
        return abs(log(ratio))
    }
}

public enum Compliance {
    /// Completed ÷ target, by duration when the session has a duration target, otherwise
    /// by distance. Nil when there is nothing to compare.
    public static func ratio(planned: PlannedSession, completed: CompletedSession) -> Double? {
        if let target = planned.targetDurationSeconds, target > 0 {
            return completed.durationSeconds / target
        }
        if let target = planned.targetDistanceMeters, target > 0, let distance = completed.distanceMeters {
            return distance / target
        }
        return nil
    }

    /// The status of a planned session given what, if anything, it was matched to.
    public static func status(planned: PlannedSession, matched: CompletedSession?, today: Date, calendar: Calendar)
        -> PlannedStatus
    {
        guard let matched else {
            return calendar.startOfDay(for: planned.date) < calendar.startOfDay(for: today) ? .missed : .planned
        }
        // A session with no target is done once anything was matched to it.
        guard let ratio = ratio(planned: planned, completed: matched) else { return .done }
        if ratio > AnalysisConstants.doneRange.upperBound { return .overdone }
        if ratio >= AnalysisConstants.doneRange.lowerBound { return .done }
        // Anything short of the done range was still started, so it is partial rather than missed.
        return .partial
    }

    /// Load a session is expected to produce: duration × the default intensity for its type.
    public static func estimatedLoad(sessionType: SessionType, durationSeconds: Double?) -> Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return durationSeconds / 60
            * (AnalysisConstants.defaultIntensity[sessionType] ?? AnalysisConstants.fallbackIntensity)
    }
}

/// One planned session's contribution to a week.
public struct SessionOutcome: Sendable, Equatable {
    public var status: PlannedStatus
    public var plannedLoad: Double
    public var achievedLoad: Double

    public init(status: PlannedStatus, plannedLoad: Double, achievedLoad: Double) {
        self.status = status
        self.plannedLoad = plannedLoad
        self.achievedLoad = achievedLoad
    }

    public init(planned: PlannedSession, matched: CompletedSession?, status: PlannedStatus) {
        self.status = status
        plannedLoad = Compliance.estimatedLoad(
            sessionType: planned.sessionType, durationSeconds: planned.targetDurationSeconds)
        // Until a measured load exists, estimate it the same way as the plan so the two compare fairly.
        achievedLoad =
            matched.map {
                $0.load
                    ?? Compliance.estimatedLoad(sessionType: planned.sessionType, durationSeconds: $0.durationSeconds)
            } ?? 0
    }
}

public struct WeekCompliance: Sendable, Equatable {
    public var planned = 0
    /// Done or overdone.
    public var completed = 0
    public var partial = 0
    public var missed = 0
    public var upcoming = 0
    public var plannedLoad = 0.0
    public var achievedLoad = 0.0

    /// Rest and flex days are left out before calling this.
    public init(_ outcomes: [SessionOutcome]) {
        for outcome in outcomes {
            planned += 1
            plannedLoad += outcome.plannedLoad
            achievedLoad += outcome.achievedLoad
            switch outcome.status {
            case .done, .overdone: completed += 1
            case .partial: partial += 1
            case .missed, .skipped: missed += 1
            case .planned: upcoming += 1
            }
        }
    }

    public var sessionFraction: Double? {
        planned > 0 ? Double(completed) / Double(planned) : nil
    }

    public var loadFraction: Double? {
        plannedLoad > 0 ? achievedLoad / plannedLoad : nil
    }
}
