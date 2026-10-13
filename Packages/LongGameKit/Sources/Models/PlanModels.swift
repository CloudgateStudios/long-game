import Analysis
import Foundation
import SwiftData

// CloudKit rules: every property optional or defaulted, no unique constraints,
// every relationship optional with an inverse. Enums are stored as raw strings.
//
// Calendar days are stored as `CalendarDay` stamps under their original field names
// (`date`, `startDate`, `endDate`, `targetDate`), because a store that syncs with CloudKit
// cannot rename a property. Code reads and writes them through `day`, `startDay`, `endDay`
// and `targetDay`, which give the start of that day on this device. Use the stored fields
// only in predicates and sort descriptors, compared against other stamps.

@Model
public final class Goal {
    public var uuid: UUID = UUID()
    @Attribute(.allowsCloudEncryption) public var title: String = ""
    public var typeRaw: String = GoalType.event.rawValue
    public var eventSportRaw: String?
    public var eventDistanceMeters: Double?
    /// The day of the event or deadline, as a `CalendarDay` stamp. Use `targetDay`.
    public var targetDate: Date?
    /// Free-text target, for example "finish under 1:50".
    @Attribute(.allowsCloudEncryption) public var targetMetric: String = ""
    @Attribute(.allowsCloudEncryption) public var targetFinishSeconds: Double?
    public var priorityRaw: String = GoalPriority.a.rawValue
    public var statusRaw: String = GoalStatus.active.rawValue
    @Attribute(.allowsCloudEncryption) public var notes: String = ""
    public var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \TrainingPlan.goal)
    public var plans: [TrainingPlan]? = []

    public init(
        title: String,
        type: GoalType = .event,
        eventSport: Sport? = nil,
        eventDistanceMeters: Double? = nil,
        targetDate: Date? = nil,
        priority: GoalPriority = .a
    ) {
        self.title = title
        self.typeRaw = type.rawValue
        self.eventSportRaw = eventSport?.rawValue
        self.eventDistanceMeters = eventDistanceMeters
        self.targetDate = targetDate.map { CalendarDay.stamp(for: $0) }
        self.priorityRaw = priority.rawValue
    }

    public var targetDay: Date? {
        get { targetDate.map { CalendarDay.date(for: $0) } }
        set { targetDate = newValue.map { CalendarDay.stamp(for: $0) } }
    }

    public var type: GoalType {
        get { GoalType(rawValue: typeRaw) ?? .event }
        set { typeRaw = newValue.rawValue }
    }

    public var eventSport: Sport? {
        get { eventSportRaw.flatMap(Sport.init(rawValue:)) }
        set { eventSportRaw = newValue?.rawValue }
    }

    public var priority: GoalPriority {
        get { GoalPriority(rawValue: priorityRaw) ?? .c }
        set { priorityRaw = newValue.rawValue }
    }

    public var status: GoalStatus {
        get { GoalStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
public final class TrainingPlan {
    public var uuid: UUID = UUID()
    public var name: String = ""
    /// First and last day, as `CalendarDay` stamps. Use `startDay` and `endDay`.
    public var startDate: Date = CalendarDay.stamp(for: Date())
    public var endDate: Date = CalendarDay.stamp(for: Date())
    public var originRaw: String = PlanOrigin.manual.rawValue
    public var createdAt: Date = Date()
    /// A generated plan waiting to be reviewed. Drafts are invisible to matching, the
    /// dashboard and the coach until accepted.
    public var isDraft: Bool = false
    /// The coach's explanation of a generated plan.
    @Attribute(.allowsCloudEncryption) public var coachSummary: String = ""

    public var goal: Goal?

    @Relationship(deleteRule: .cascade, inverse: \PlanPhase.plan)
    public var phases: [PlanPhase]? = []

    @Relationship(deleteRule: .cascade, inverse: \PlannedWorkout.plan)
    public var workouts: [PlannedWorkout]? = []

    public init(name: String, startDate: Date, endDate: Date, origin: PlanOrigin = .manual, goal: Goal? = nil) {
        self.name = name
        self.startDate = CalendarDay.stamp(for: startDate)
        self.endDate = CalendarDay.stamp(for: endDate)
        self.originRaw = origin.rawValue
        self.goal = goal
    }

    public var startDay: Date {
        get { CalendarDay.date(for: startDate) }
        set { startDate = CalendarDay.stamp(for: newValue) }
    }

    public var endDay: Date {
        get { CalendarDay.date(for: endDate) }
        set { endDate = CalendarDay.stamp(for: newValue) }
    }

    public var origin: PlanOrigin {
        get { PlanOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }

    public var sortedPhases: [PlanPhase] {
        (phases ?? []).sorted { $0.startDay < $1.startDay }
    }

    /// The phase whose date range (inclusive of both ends) contains `date`.
    public func phase(on date: Date, calendar: Calendar = .current) -> PlanPhase? {
        let day = calendar.startOfDay(for: date)
        return sortedPhases.first {
            calendar.startOfDay(for: $0.startDay) <= day && day <= calendar.startOfDay(for: $0.endDay)
        }
    }

    /// Planned sessions on `date`, in a stable order.
    public func workouts(on date: Date, calendar: Calendar = .current) -> [PlannedWorkout] {
        (workouts ?? [])
            .filter { calendar.isDate($0.day, inSameDayAs: date) }
            .sorted(by: PlannedWorkout.inDayOrder)
    }
}

@Model
public final class PlanPhase {
    public var kindRaw: String = PlanPhaseKind.base.rawValue
    /// First and last day, as `CalendarDay` stamps. Use `startDay` and `endDay`.
    public var startDate: Date = CalendarDay.stamp(for: Date())
    public var endDate: Date = CalendarDay.stamp(for: Date())

    public var plan: TrainingPlan?

    public init(kind: PlanPhaseKind, startDate: Date, endDate: Date) {
        self.kindRaw = kind.rawValue
        self.startDate = CalendarDay.stamp(for: startDate)
        self.endDate = CalendarDay.stamp(for: endDate)
    }

    public var startDay: Date {
        get { CalendarDay.date(for: startDate) }
        set { startDate = CalendarDay.stamp(for: newValue) }
    }

    public var endDay: Date {
        get { CalendarDay.date(for: endDate) }
        set { endDate = CalendarDay.stamp(for: newValue) }
    }

    public var kind: PlanPhaseKind {
        get { PlanPhaseKind(rawValue: kindRaw) ?? .base }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
public final class PlannedWorkout {
    /// Stable identifier the coach uses to target a session.
    public var uuid: UUID = UUID()
    /// The day as a `CalendarDay` stamp, not an instant. Read and write it through `day`.
    public var date: Date = CalendarDay.stamp(for: Date())
    /// Position among the day's sessions, lowest first. Ties fall back to creation order.
    public var orderInDay: Int = 0
    /// Shared by sessions done back to back as one outing: a brick, or the legs of a race.
    public var brickID: UUID?
    public var sportRaw: String = Sport.run.rawValue
    /// What an "other" session is, for example "Hiking" or "Curling". Empty for the
    /// modelled sports. Read it through `activity`.
    @Attribute(.allowsCloudEncryption) public var activityName: String = ""
    public var sessionTypeRaw: String = SessionType.easy.rawValue
    public var targetDurationSeconds: Double?
    public var targetDistanceMeters: Double?
    /// Zone or free-text description, for example "Z2" or "5 × 1 km at 10K pace".
    @Attribute(.allowsCloudEncryption) public var targetIntensity: String = ""
    /// Free text. Strength sessions hold exercises and sets here in v1; a structured
    /// child model can be added later as a new optional relationship.
    @Attribute(.allowsCloudEncryption) public var instructions: String = ""
    /// A run or ride as steps for a watch or bike computer, stored as JSON. Nil for a
    /// session described only in words.
    @Attribute(.allowsCloudEncryption) public var structureJSON: String?
    /// Whether this run's steps are followed by pace or heart rate. Nil follows the
    /// athlete's usual choice.
    public var runTargetsRaw: String?
    public var statusRaw: String = PlannedStatus.planned.rawValue
    public var isManualMatch: Bool = false
    public var createdAt: Date = Date()

    public var plan: TrainingPlan?
    public var matchedWorkout: CompletedWorkout?

    @Relationship(deleteRule: .nullify, inverse: \PlanSuggestion.targetWorkout)
    public var suggestions: [PlanSuggestion]? = []

    public init(
        date: Date,
        sport: Sport,
        sessionType: SessionType,
        targetDurationSeconds: Double? = nil,
        targetDistanceMeters: Double? = nil,
        targetIntensity: String = "",
        instructions: String = ""
    ) {
        self.date = CalendarDay.stamp(for: date)
        self.sportRaw = sport.rawValue
        self.sessionTypeRaw = sessionType.rawValue
        self.targetDurationSeconds = targetDurationSeconds
        self.targetDistanceMeters = targetDistanceMeters
        self.targetIntensity = targetIntensity
        self.instructions = instructions
    }

    /// Start of the day in the device's calendar.
    public var day: Date {
        get { CalendarDay.date(for: date) }
        set { date = CalendarDay.stamp(for: newValue) }
    }

    /// The order sessions on one day are shown and done in.
    public static func inDayOrder(_ a: PlannedWorkout, _ b: PlannedWorkout) -> Bool {
        (a.orderInDay, a.createdAt, a.uuid.uuidString) < (b.orderInDay, b.createdAt, b.uuid.uuidString)
    }

    public var sport: Sport {
        get { Sport(rawValue: sportRaw) ?? .other }
        set { sportRaw = newValue.rawValue }
    }

    public var sessionType: SessionType {
        get { SessionType(rawValue: sessionTypeRaw) ?? .other }
        set { sessionTypeRaw = newValue.rawValue }
    }

    /// The named activity of an "other" session; nil for a modelled sport or when unnamed.
    public var activity: String? {
        get { sport == .other && !activityName.isEmpty ? activityName : nil }
        set { activityName = ActivityName.normalized(newValue) ?? "" }
    }

    /// "Hiking" for a named "other" session, otherwise the sport's name.
    public var sportDisplayName: String { activity ?? sport.displayName }

    public var status: PlannedStatus {
        get { PlannedStatus(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue }
    }

    public var runTargets: RunTargetMode? {
        get { runTargetsRaw.flatMap(RunTargetMode.init(rawValue:)) }
        set { runTargetsRaw = newValue?.rawValue }
    }

    public var structure: StructuredWorkout? {
        get {
            guard let structureJSON,
                let workout = try? JSONDecoder().decode(StructuredWorkout.self, from: Data(structureJSON.utf8))
            else { return nil }
            return workout.isEmpty ? nil : workout
        }
        set {
            guard let workout = newValue?.normalized(), !workout.isEmpty, let data = try? JSONEncoder().encode(workout)
            else {
                structureJSON = nil
                return
            }
            structureJSON = String(decoding: data, as: UTF8.self)
        }
    }
}
