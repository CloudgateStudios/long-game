import Analysis
import Foundation
import Models
import SwiftData

/// What a generated plan should cover.
public struct PlanRequest: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var goalTitle: String?
    public var goalDate: Date?

    public init(start: Date, end: Date, goalTitle: String? = nil, goalDate: Date? = nil) {
        self.start = start
        self.end = end
        self.goalTitle = goalTitle
        self.goalDate = goalDate
    }
}

public struct BuiltPayload: Sendable {
    public var payload: CoachPayload
    /// Exactly what is sent, and what is stored with the review.
    public var json: String
    public var periodStart: Date
    public var periodEnd: Date
    /// The short session IDs used in the payload, mapped back to planned sessions.
    public var sessionIDs: [String: UUID]
}

/// Builds the coach's view of the athlete from the store: summaries and per-workout
/// records, never raw sample streams.
public enum CoachPayloadBuilder {
    public static func build(
        in context: ModelContext,
        trigger: ReviewTrigger,
        planID: UUID? = nil,
        planRequest: PlanRequest? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> BuiltPayload {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        let historyStart = day(-CoachConfiguration.historyDays)
        let planEnd = day(CoachConfiguration.planLookaheadDays)
        let dateStyle = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        func text(_ date: Date) -> String { date.formatted(dateStyle) }

        // Profile
        var profileDescriptor = FetchDescriptor<AthleteProfile>(sortBy: [SortDescriptor(\.createdAt)])
        profileDescriptor.fetchLimit = 1
        let athlete = try context.fetch(profileDescriptor).first
        let zones = try LoadRecalculator.resolveZones(in: context, now: now, calendar: calendar)
        let profile = CoachPayload.Profile(
            age: athlete?.age(on: now, calendar: calendar),
            sex: athlete?.biologicalSex?.rawValue,
            heightCm: athlete?.heightCm.map(round0),
            weightKg: athlete?.weightKg.map(round1),
            maxHR: zones.maxHR.map(round0),
            restingHR: zones.restingHR.map(round0),
            zoneUpperBounds: zones.bounds,
            ftpWatts: athlete?.ftpWatts.map(round0),
            thresholdRunPaceSecPerKm: athlete?.thresholdRunPaceSecondsPerKm.map(round0),
            thresholdSwimPaceSecPer100m: athlete?.thresholdSwimPaceSecondsPer100m.map(round0),
            sports: (athlete?.enabledSports ?? [.swim, .bike, .run, .strength]).map(\.rawValue),
            availabilityHoursMonToSun: athlete?.availabilityHours ?? [],
            notes: athlete.flatMap { $0.coachNotes.isEmpty ? nil : $0.coachNotes }
        )

        // Goals
        let goals = try context.fetch(FetchDescriptor<Goal>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { $0.status != .abandoned }
            .sorted { ($0.priority, $0.targetDate ?? .distantFuture) < ($1.priority, $1.targetDate ?? .distantFuture) }
            .map { goal in
                CoachPayload.Goal(
                    title: goal.title,
                    type: goal.type.rawValue,
                    priority: goal.priority.rawValue,
                    status: goal.status.rawValue,
                    sport: goal.eventSport?.rawValue,
                    distanceKm: goal.eventDistanceMeters.map { round1($0 / 1000) },
                    date: goal.targetDate.map(text),
                    daysAway: goal.targetDate.flatMap {
                        calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: $0)).day
                    },
                    target: goal.targetMetric.isEmpty ? nil : goal.targetMetric
                )
            }

        // Plan: the chosen one, else the one covering today, else the most recent.
        let plans = try context.fetch(FetchDescriptor<TrainingPlan>(sortBy: [SortDescriptor(\.startDate)])).filter {
            !$0.isDraft
        }
        let plan =
            plans.first { $0.uuid == planID } ?? plans.first { $0.startDate <= now && now <= $0.endDate } ?? plans.last
        let sessions = (plan?.workouts ?? [])
            .filter { $0.date >= historyStart && $0.date < planEnd }
            .sorted { ($0.date, $0.createdAt, $0.uuid.uuidString) < ($1.date, $1.createdAt, $1.uuid.uuidString) }
        let shortIDs = shortIDs(for: sessions.map(\.uuid))
        var sessionIDs: [String: UUID] = [:]
        for (uuid, short) in shortIDs { sessionIDs[short] = uuid }

        let payloadPlan = plan.map { plan in
            CoachPayload.Plan(
                start: text(plan.startDate),
                end: text(plan.endDate),
                phases: plan.sortedPhases.map {
                    .init(kind: $0.kind.rawValue, start: text($0.startDate), end: text($0.endDate))
                },
                sessions: sessions.map { session in
                    CoachPayload.Session(
                        id: shortIDs[session.uuid] ?? session.uuid.uuidString,
                        date: text(session.date),
                        sport: session.sport.rawValue,
                        type: session.sessionType.rawValue,
                        minutes: session.targetDurationSeconds.map { round0($0 / 60) },
                        km: session.targetDistanceMeters.map { round1($0 / 1000) },
                        intensity: session.targetIntensity.isEmpty ? nil : session.targetIntensity,
                        instructions: session.instructions.isEmpty ? nil : session.instructions,
                        status: session.status.rawValue,
                        percentOfTarget: session.complianceRatio.map { Int(($0 * 100).rounded()) }
                    )
                }
            )
        }

        // Workouts: only the recording that counts for each session.
        let loadHistoryStart = day(-(CoachConfiguration.historyDays + AnalysisConstants.chronicLoadDays))
        let allWorkouts = try context.fetch(
            FetchDescriptor<CompletedWorkout>(
                predicate: #Predicate { $0.isPrimary && $0.start >= loadHistoryStart },
                sortBy: [SortDescriptor(\.start)]
            ))
        let workouts = allWorkouts.filter { $0.start >= historyStart }.map { workout in
            CoachPayload.Workout(
                date: text(workout.start),
                sport: workout.sport.rawValue,
                activity: workout.sport == .other && !workout.activityName.isEmpty ? workout.activityName : nil,
                minutes: round0(workout.durationSeconds / 60),
                km: workout.distanceMeters.map { round1($0 / 1000) },
                avgHR: workout.averageHR.map(round0),
                maxHR: workout.maxHR.map(round0),
                zoneMinutes: workout.zoneSeconds.map { $0.map { round0($0 / 60) } },
                watts: workout.averagePowerWatts.map(round0),
                effort: workout.effortScore.map(round1),
                load: workout.load.map(round0),
                loadEstimated: workout.confidence == .estimated ? true : nil,
                sessionId: workout.plannedWorkout.flatMap { shortIDs[$0.uuid] }
            )
        }

        // Load trend
        let loadDays = LoadTrend.days(
            allWorkouts.compactMap(\.loadEntry), from: historyStart, to: today, calendar: calendar)
        let latest = loadDays.last
        var weeks: [Date: CoachPayload.Week] = [:]
        for loadDay in loadDays {
            let start = calendar.dateInterval(of: .weekOfYear, for: loadDay.date)?.start ?? loadDay.date
            var week = weeks[start] ?? CoachPayload.Week(weekStart: text(start), load: 0, loadBySport: [:])
            week.load += loadDay.total
            for (sport, load) in loadDay.bySport { week.loadBySport[sport.rawValue, default: 0] += load }
            weeks[start] = week
        }
        let payloadWeeks = weeks.keys.sorted().compactMap { start -> CoachPayload.Week? in
            guard var week = weeks[start] else { return nil }
            week.load = round0(week.load)
            week.loadBySport = week.loadBySport.mapValues(round0)
            if let plan {
                let compliance = plan.compliance(
                    on: PlanCalendar.weekDays(containing: start, calendar: calendar), calendar: calendar)
                if compliance.planned > 0 {
                    week.sessionsPlanned = compliance.planned
                    week.sessionsDone = compliance.completed
                    week.sessionsPartial = compliance.partial
                    week.sessionsMissed = compliance.missed
                    week.percentOfPlannedLoad = compliance.loadFraction.map { Int(($0 * 100).rounded()) }
                }
            }
            return week
        }
        let load = CoachPayload.Load(
            last7DayDailyAverage: round0(latest?.acute ?? 0),
            last28DayDailyAverage: round0(latest?.chronic ?? 0),
            loadRatio: latest?.ratio.map(round2),
            loadRatioOutsideSteadyRange: latest?.isRatioFlagged ?? false,
            weeks: payloadWeeks
        )

        // Daily metrics, with a baseline window behind them
        let metricsStart = day(-(CoachConfiguration.historyDays + AnalysisConstants.baselineDays))
        let metrics = try context.fetch(
            FetchDescriptor<DailyMetrics>(
                predicate: #Predicate { $0.date >= metricsStart },
                sortBy: [SortDescriptor(\.date)]
            ))
        func baseline(_ value: KeyPath<DailyMetrics, Double?>, _ direction: RecoveryDirection) -> [Date: BaselinePoint]
        {
            let readings = metrics.compactMap { day in day[keyPath: value].map { (date: day.date, value: $0) } }
            let points = RecoveryBaseline.points(readings, direction: direction, calendar: calendar)
            return Dictionary(points.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let hrv = baseline(\.hrvSDNN, .lowIsWorse)
        let restingHR = baseline(\.restingHR, .highIsWorse)
        let sleep = baseline(\.sleepSeconds, .lowIsWorse)
        let loadByDay = Dictionary(loadDays.map { ($0.date, $0.total) }, uniquingKeysWith: { first, _ in first })

        let daily = metrics.filter { $0.date >= day(-(CoachConfiguration.historyDays - 1)) }.map { metric in
            var flags: [String] = []
            if hrv[metric.date]?.isFlagged == true { flags.append("hrvLow") }
            if restingHR[metric.date]?.isFlagged == true { flags.append("restingHRHigh") }
            if sleep[metric.date]?.isFlagged == true { flags.append("sleepShort") }
            return CoachPayload.Day(
                date: text(metric.date),
                restingHR: metric.restingHR.map(round0),
                hrv: metric.hrvSDNN.map(round0),
                sleepHours: metric.sleepSeconds.map { round1($0 / 3600) },
                deepSleepHours: metric.sleepDeepSeconds.map { round1($0 / 3600) },
                remSleepHours: metric.sleepREMSeconds.map { round1($0 / 3600) },
                respiratoryRate: metric.respiratoryRate.map(round1),
                steps: metric.steps.map(round0),
                vo2Max: metric.vo2Max.map(round1),
                weightKg: metric.bodyMassKg.map(round1),
                load: loadByDay[calendar.startOfDay(for: metric.date)].flatMap { $0 > 0 ? round0($0) : nil },
                flags: flags.isEmpty ? nil : flags
            )
        }
        func latestBaseline(_ points: [Date: BaselinePoint], scale: Double = 1) -> CoachPayload.Baseline? {
            guard let point = points.values.filter({ $0.mean != nil }).max(by: { $0.date < $1.date }),
                let mean = point.mean, let deviation = point.deviation
            else { return nil }
            return .init(mean: round1(mean / scale), standardDeviation: round1(deviation / scale))
        }
        let baselines = CoachPayload.Baselines(
            hrv: latestBaseline(hrv),
            restingHR: latestBaseline(restingHR),
            sleepHours: latestBaseline(sleep, scale: 3600)
        )

        // Previous review, so the coach knows what it said and what was taken up
        var reviewDescriptor = FetchDescriptor<CoachReview>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        reviewDescriptor.fetchLimit = 5
        let previous = try context.fetch(reviewDescriptor).first { $0.trigger != .planGeneration }
        let previousReview = previous.map { review in
            CoachPayload.PreviousReview(
                date: text(review.date),
                assessment: String(review.assessment.prefix(CoachConfiguration.previousAssessmentCharacters)),
                suggestions: (review.suggestions ?? []).sorted { $0.createdAt < $1.createdAt }.map {
                    .init(
                        action: $0.action.rawValue, session: $0.targetSummary, rationale: $0.rationale,
                        status: $0.status.rawValue)
                }
            )
        }

        let payload = CoachPayload(
            today: text(today),
            weekday: today.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide)),
            reviewType: trigger.rawValue,
            profile: profile,
            goals: goals,
            plan: payloadPlan,
            workouts: workouts,
            daily: daily,
            baselines: baselines,
            load: load,
            previousReview: previousReview,
            planRequest: planRequest.map { request in
                CoachPayload.PlanRequest(
                    start: text(request.start),
                    end: text(request.end),
                    weeks: max(
                        1,
                        ((calendar.dateComponents(
                            [.day], from: calendar.startOfDay(for: request.start),
                            to: calendar.startOfDay(for: request.end)
                        ).day ?? 0) + 1) / 7),
                    goal: request.goalTitle,
                    goalDate: request.goalDate.map(text)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        return BuiltPayload(
            payload: payload, json: json, periodStart: historyStart, periodEnd: today, sessionIDs: sessionIDs)
    }

    /// The same data with the plan-writing prompt, to paste into the Claude app.
    public static func planExportText(for built: BuiltPayload) -> String {
        """
        \(CoachConfiguration.planPrompt)

        Reply in plain prose rather than JSON: a short summary, the phases with their dates, then the sessions week by \
        week, one line each with date, sport, type, duration and intensity.

        Here is my training data and what I am asking for:

        \(built.json)
        """
    }

    /// The same payload with the coach prompt, as text to paste into the Claude app.
    /// There the reply is read by a person, so it asks for prose rather than JSON.
    public static func exportText(for built: BuiltPayload) -> String {
        """
        \(CoachConfiguration.systemPrompt)

        Reply in plain prose rather than JSON: your assessment first, then any flags, then a numbered list of suggested \
        changes. For each change give the session's date, sport and type, what to change it to, and why.

        Here is my training data:

        \(built.json)
        """
    }

    /// Eight characters of each UUID are enough to tell a few dozen sessions apart and
    /// cost far fewer tokens; fall back to the full value on the rare collision.
    private static func shortIDs(for uuids: [UUID]) -> [UUID: String] {
        let short = uuids.map { String($0.uuidString.prefix(8)).lowercased() }
        let isUnique = Set(short).count == short.count
        return Dictionary(
            zip(uuids, isUnique ? short : uuids.map { $0.uuidString.lowercased() }),
            uniquingKeysWith: { first, _ in first })
    }

    private static func round0(_ value: Double) -> Double { value.rounded() }
    private static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
