import Analysis
import Foundation
import Testing

@Suite struct PlanMatcherTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func time(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func planned(_ sport: Sport, day: Int, minutes: Double? = nil, meters: Double? = nil) -> PlannedSession {
        PlannedSession(
            id: UUID(), date: time(day), sport: sport, targetDurationSeconds: minutes.map { $0 * 60 },
            targetDistanceMeters: meters)
    }

    func done(_ sport: Sport, day: Int, hour: Int = 7, minutes: Double = 45, meters: Double? = nil) -> CompletedSession
    {
        CompletedSession(
            id: UUID(), start: time(day, hour), sport: sport, durationSeconds: minutes * 60, distanceMeters: meters)
    }

    @Test func matchesSameSportOnTheSameDay() {
        let run = planned(.run, day: 12)
        let swim = planned(.swim, day: 12)
        let didRun = done(.run, day: 12)
        let didRide = done(.bike, day: 12)
        let result = PlanMatcher.match(planned: [run, swim], completed: [didRun, didRide], calendar: calendar)
        #expect(result == [run.id: didRun.id])
    }

    @Test func aNamedActivityOnlyMatchesItsOwnKind() {
        var hike = planned(.other, day: 12)
        hike.activity = "hiking"
        let unnamed = planned(.other, day: 15)
        var didYoga = done(.other, day: 12)
        didYoga.activity = "Yoga"
        var didHike = done(.other, day: 13)
        didHike.activity = "Hiking"
        var didCurl = done(.other, day: 15)
        didCurl.activity = "Curling"
        let result = PlanMatcher.match(
            planned: [hike, unnamed], completed: [didYoga, didHike, didCurl], calendar: calendar)
        // The hike skips the yoga on its own day for the hike a day later; a session with
        // no name takes any activity.
        #expect(result == [hike.id: didHike.id, unnamed.id: didCurl.id])

        // A workout with no name can still be the hike.
        let nameless = done(.other, day: 12)
        #expect(PlanMatcher.match(planned: [hike], completed: [nameless], calendar: calendar) == [hike.id: nameless.id])
    }

    @Test func fallsBackToTheDayBeforeOrAfter() {
        let run = planned(.run, day: 12)
        let early = done(.run, day: 11, hour: 22)
        #expect(PlanMatcher.match(planned: [run], completed: [early], calendar: calendar) == [run.id: early.id])
        let late = done(.run, day: 13, hour: 1)
        #expect(PlanMatcher.match(planned: [run], completed: [late], calendar: calendar) == [run.id: late.id])
    }

    @Test func doesNotReachTwoDaysAway() {
        let run = planned(.run, day: 12)
        #expect(PlanMatcher.match(planned: [run], completed: [done(.run, day: 14)], calendar: calendar).isEmpty)
    }

    @Test func sameDayBeatsANeighbouringDay() {
        // Runs planned on consecutive days, one run done on the second day: it belongs
        // to the second session even though the first is looked at first.
        let first = planned(.run, day: 12)
        let second = planned(.run, day: 13)
        let workout = done(.run, day: 13)
        #expect(
            PlanMatcher.match(planned: [first, second], completed: [workout], calendar: calendar) == [
                second.id: workout.id
            ])
    }

    @Test func isOneToOne() {
        let a = planned(.run, day: 12)
        let b = planned(.run, day: 13)
        let workout = done(.run, day: 12)
        let result = PlanMatcher.match(planned: [a, b], completed: [workout], calendar: calendar)
        #expect(result == [a.id: workout.id])
    }

    @Test func twoSessionsOnOneDayTakeTheBestFit() {
        let short = planned(.run, day: 12, minutes: 30)
        let long = planned(.run, day: 12, minutes: 90)
        let morning = done(.run, day: 12, hour: 6, minutes: 85)
        let evening = done(.run, day: 12, hour: 18, minutes: 28)
        let result = PlanMatcher.match(planned: [short, long], completed: [morning, evening], calendar: calendar)
        #expect(result == [short.id: evening.id, long.id: morning.id])
    }

    @Test func withNoTargetsTheEarliestWorkoutWins() {
        let run = planned(.run, day: 12)
        let later = done(.run, day: 12, hour: 18)
        let earlier = done(.run, day: 12, hour: 6)
        #expect(
            PlanMatcher.match(planned: [run], completed: [later, earlier], calendar: calendar) == [run.id: earlier.id])
    }
}

@Suite struct ComplianceTests {
    let calendar = Calendar(identifier: .gregorian)
    let today = Date(timeIntervalSince1970: 1_790_000_000)

    func planned(daysFromToday: Int = -1, minutes: Double? = 60, meters: Double? = nil, type: SessionType = .easy)
        -> PlannedSession
    {
        PlannedSession(
            id: UUID(), date: today.addingTimeInterval(Double(daysFromToday) * 86_400), sport: .run, sessionType: type,
            targetDurationSeconds: minutes.map { $0 * 60 }, targetDistanceMeters: meters)
    }

    func done(minutes: Double, meters: Double? = nil, load: Double? = nil) -> CompletedSession {
        CompletedSession(
            id: UUID(), start: today, sport: .run, durationSeconds: minutes * 60, distanceMeters: meters, load: load)
    }

    func status(_ minutes: Double) -> PlannedStatus {
        Compliance.status(planned: planned(), matched: done(minutes: minutes), today: today, calendar: calendar)
    }

    @Test func statusFollowsTheDurationBands() {
        #expect(status(20) == .partial)
        #expect(status(30) == .partial)
        #expect(status(47.9) == .partial)
        #expect(status(48) == .done)
        #expect(status(60) == .done)
        #expect(status(72) == .done)
        #expect(status(72.1) == .overdone)
    }

    @Test func distanceIsUsedOnlyWithoutADurationTarget() {
        let byDistance = planned(minutes: nil, meters: 10_000)
        #expect(
            Compliance.status(
                planned: byDistance, matched: done(minutes: 5, meters: 9_000), today: today, calendar: calendar)
                == .done)
        #expect(
            Compliance.status(
                planned: byDistance, matched: done(minutes: 500, meters: 6_000), today: today, calendar: calendar)
                == .partial)
        let both = planned(minutes: 60, meters: 10_000)
        #expect(Compliance.ratio(planned: both, completed: done(minutes: 30, meters: 10_000)) == 0.5)
    }

    @Test func aSessionWithNoTargetIsDoneOnceMatched() {
        let open = planned(minutes: nil)
        #expect(Compliance.status(planned: open, matched: done(minutes: 5), today: today, calendar: calendar) == .done)
        // A distance target with no recorded distance cannot be judged either.
        let byDistance = planned(minutes: nil, meters: 5_000)
        #expect(
            Compliance.status(planned: byDistance, matched: done(minutes: 30), today: today, calendar: calendar)
                == .done)
    }

    @Test func unmatchedSessionsAreMissedOnlyOnceTheDayHasPassed() {
        #expect(
            Compliance.status(planned: planned(daysFromToday: -1), matched: nil, today: today, calendar: calendar)
                == .missed)
        #expect(
            Compliance.status(planned: planned(daysFromToday: 0), matched: nil, today: today, calendar: calendar)
                == .planned)
        #expect(
            Compliance.status(planned: planned(daysFromToday: 3), matched: nil, today: today, calendar: calendar)
                == .planned)
    }

    @Test func weekSummaryCountsSessionsAndLoad() {
        let easy = planned(minutes: 60)  // 120 planned
        let tempo = planned(minutes: 40, type: .tempo)  // 140 planned
        let outcomes = [
            // 120 achieved (estimated)
            SessionOutcome(planned: easy, matched: done(minutes: 60), status: .done),
            // measured load wins
            SessionOutcome(planned: tempo, matched: done(minutes: 20, load: 90), status: .partial),
            SessionOutcome(planned: easy, matched: nil, status: .missed),
            SessionOutcome(planned: easy, matched: nil, status: .planned),
        ]
        let week = WeekCompliance(outcomes)
        #expect(week.planned == 4)
        #expect(week.completed == 1)
        #expect(week.partial == 1)
        #expect(week.missed == 1)
        #expect(week.upcoming == 1)
        #expect(week.plannedLoad == 500)
        #expect(week.achievedLoad == 210)
        #expect(week.sessionFraction == 0.25)
        #expect(week.loadFraction == 0.42)
    }

    @Test func anEmptyWeekHasNoFractions() {
        let week = WeekCompliance([])
        #expect(week.sessionFraction == nil)
        #expect(week.loadFraction == nil)
    }
}
