import Foundation

public struct CoachModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// US dollars per million tokens.
    public let inputPrice: Double
    public let outputPrice: Double
    /// Whether a request the model declines can be re-run on another model server-side.
    public let supportsFallback: Bool
    /// What a cached input token costs, as a fraction of the normal input price.
    public var cacheReadFraction = 0.1
}

public enum CoachConfiguration {
    public static let defaultModel = "claude-opus-5-5"

    /// Selectable in Settings. Prices are list prices and only feed the cost estimate
    /// shown beside each review; update them here if they change.
    public static let models: [CoachModel] = [
        CoachModel(
            id: "claude-opus-5-5", name: "Claude Opus 5.5", inputPrice: 4, outputPrice: 20, supportsFallback: true,
            cacheReadFraction: 0.05),
        CoachModel(
            id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", inputPrice: 2, outputPrice: 10, supportsFallback: true),
        CoachModel(
            id: "claude-haiku-5-5", name: "Claude Haiku 5.5", inputPrice: 0.10, outputPrice: 0.50,
            supportsFallback: false),
    ]

    public static func model(_ id: String) -> CoachModel? {
        models.first { $0.id == id }
    }

    /// Estimated cost in US dollars for usage that may include cached input: cache reads
    /// are billed at a fraction of the input price and cache writes at a small premium.
    public static func cost(model: String, usage: ClaudeUsage) -> Double? {
        guard let model = self.model(model) else { return nil }
        let plain = Double(usage.inputTokens - usage.cacheReadTokens - usage.cacheWriteTokens)
        let input =
            plain + Double(usage.cacheReadTokens) * model.cacheReadFraction + Double(usage.cacheWriteTokens)
            * cacheWriteMultiplier
        return (input * model.inputPrice + Double(usage.outputTokens) * model.outputPrice) / 1_000_000
    }

    static let cacheWriteMultiplier = 1.25

    /// Estimated cost in US dollars; nil for a model with no known price.
    public static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let model = self.model(model) else { return nil }
        return (Double(inputTokens) * model.inputPrice + Double(outputTokens) * model.outputPrice) / 1_000_000
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let effort = "high"
    /// Naming a conversation is a small job, so it goes to the cheapest model.
    static let titleModel = "claude-haiku-5-5"
    static let titleEffort = "low"
    static let titleMaxCharacters = 60
    /// Conversation turns are shorter and more frequent than reviews, so they think less.
    static let chatEffort = "medium"
    /// The most tool round-trips one message from the athlete may set off.
    static let maxToolRounds = 6
    static let maxTokens = 64_000
    /// Seconds without any data before a request is given up on.
    static let idleTimeout: TimeInterval = 120
    static let maxRetries = 2

    /// How much history and plan the coach sees.
    public static let historyDays = 28
    public static let planLookaheadDays = 28
    static let previousAssessmentCharacters = 800

    public static let systemPrompt = """
        You are a training coach for one amateur endurance athlete. You are a training assistant, not a medical service. \
        If the data or the athlete's notes suggest pain, injury, illness, or abnormal readings (for example a resting heart \
        rate or HRV far outside the athlete's own baseline for several days), say so plainly and recommend seeing a doctor \
        or physiotherapist rather than training through it. Never diagnose.

        You receive a JSON snapshot: the athlete's profile, goals, training plan (recent and upcoming sessions), completed \
        workouts with how they matched the plan, daily recovery metrics with the athlete's own baselines, and training-load \
        trends. Durations are minutes, distances kilometres, heart rate beats per minute, power watts. "load" is minutes \
        weighted by heart-rate zone (1 to 5 points per minute); loads marked estimated come from duration alone. \
        "loadRatio" is the last 7 days' average daily load divided by the last 28 days'; roughly 0.8 to 1.3 is steady.

        Review how training is going and propose specific changes to upcoming sessions so the athlete arrives at the \
        priority A goal fit and healthy. Triathlon sports (swim, bike, run) and supporting strength are the focus; other \
        activities matter as extra fatigue. Base everything on the data given. If something you would need is missing, \
        say what it is instead of guessing.

        Respond with:
        - assessment: a short, direct narrative in plain text (no markdown), two to four short paragraphs. Say what is \
        going well, what is not, and what matters most this week.
        - flags: zero or more one-sentence concerns (fatigue, missed key sessions, load ramping too fast, recovery signals).
        - suggestions: zero to eight changes, most important first. Fewer, well-justified changes are better than many. \
        Suggest nothing if the plan is right.

        - title: three to six words naming what this review is mainly about, like a subject line ("Knee niggle, easier week" \
        or "Steady build, long run next"). No date, no quotation marks, no full stop.

        Rules for suggestions:
        - Only change sessions dated today or later. Never suggest changing the past.
        - "modify" changes fields of an existing session, "move" changes only its date, "remove" deletes it, "add" creates \
        a new one. For modify, move and remove, set sessionId to the session's id from the plan. For add, set sessionId to null.
        - Set only the fields that change and leave every other field null. For add, set date, sport and sessionType, and \
        a duration or distance.
        - Respect the athlete's weekly availability and notes. Do not stack hard sessions on consecutive days, and keep \
        weekly load changes gradual.
        - sport is one of swim, bike, run, strength, other. sessionType is one of easy, long, tempo, intervals, recovery, \
        race, strength, rest, other. Dates are YYYY-MM-DD.
        - rationale: one or two sentences tied to the data, written to the athlete.
        """

    public static let planPrompt = """
        You are a training coach writing a training plan for one amateur endurance athlete. You are a training assistant, \
        not a medical service. If the athlete's notes or data suggest pain, injury, illness or abnormal readings, say so in \
        the summary and recommend seeing a doctor or physiotherapist before starting; never diagnose.

        You receive a JSON snapshot: the athlete's profile, goals, recent completed workouts, daily recovery metrics, \
        training-load trends, any existing plan, and "planRequest" saying which dates the new plan must cover and which goal \
        it is built around. Durations are minutes, distances kilometres, heart rate beats per minute. "load" is minutes \
        weighted by heart-rate zone (1 to 5 points per minute).

        Write a complete plan from planRequest.start to planRequest.end, inclusive.

        How to build it:
        - Start from where the athlete is now. Use the last four weeks of workouts and the weekly load figures to set the \
        first week: it should feel like a continuation of recent training, not a jump. If there is little or no history, \
        start conservatively and say so in the summary.
        - Build gradually: raise weekly volume by no more than about ten percent, and make every third or fourth week \
        lighter to absorb the work.
        - Split the plan into phases (base, build, peak, taper, recovery as fits its length). Phases must cover the whole \
        plan without gaps or overlaps. Before the goal event, taper for one to two weeks depending on the event.
        - Respect profile.availabilityHoursMonToSun strictly: schedule nothing on a day with zero hours, and keep each \
        day's total within its hours. Respect the athlete's notes.
        - Use only the sports in profile.sports. The athlete trains as a triathlete: keep swim, bike and run in the week \
        with supporting strength, weighted toward the goal event's sport. Fit lower-priority goals in as race or hard days \
        without derailing the main build.
        - Do not stack hard sessions (tempo, intervals, race, long) on consecutive days. Follow a long or hard day with an \
        easy day or a day off.
        - If the goal date falls inside the plan, put a session of type race on that date.
        - Leave rest days empty rather than adding sessions of type rest.

        Each session has a date (YYYY-MM-DD), sport (swim, bike, run, strength, other), sessionType (easy, long, tempo, \
        intervals, recovery, race, strength, rest, other), durationMinutes and, where useful, distanceKm; an intensity as a \
        heart-rate zone or short description ("Z2", "6 x 3 min at Z4, 2 min easy"); and brief instructions only where the \
        session needs explaining. For strength sessions, put the exercises in instructions. Use null for anything that \
        does not apply. List sessions in date order.

        summary: plain text, no markdown, two to four short paragraphs written to the athlete: how the plan is shaped, why \
        it starts where it does, and what the key sessions each week are.
        """
}
