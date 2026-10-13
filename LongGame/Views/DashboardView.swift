import Analysis
import Models
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \Goal.targetDate) private var goals: [Goal]
    @Query(sort: \CompletedWorkout.start, order: .reverse) private var workouts: [CompletedWorkout]
    @Query(sort: \DailyMetrics.date) private var days: [DailyMetrics]
    @Query(sort: \PlannedWorkout.createdAt) private var planned: [PlannedWorkout]
    @Query(sort: \TrainingPlan.startDate) private var plans: [TrainingPlan]
    @SceneStorage("selectedSection") private var selection: AppSection = .today
    @State private var isShowingGoals = false

    private static let trendDays = 42
    private static let weeklyChartWeeks = 8
    private static let recoveryDays = 28

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: .now) }

    private var plannedToday: [PlannedWorkout] {
        planned.filter { calendar.isDateInToday($0.day) && $0.plan?.isDraft != true }
            .sorted(by: PlannedWorkout.inDayOrder)
    }

    /// Every active goal still ahead, soonest first.
    private var upcomingGoals: [Goal] {
        goals
            .filter { $0.status == .active && ($0.targetDay ?? .distantPast) >= today }
            .sorted { ($0.targetDay ?? .distantFuture, $0.priority) < ($1.targetDay ?? .distantFuture, $1.priority) }
    }

    /// The goal the header names: the highest priority still ahead, soonest first among equals.
    private var headlineGoal: Goal? {
        upcomingGoals.min {
            ($0.priority, $0.targetDay ?? .distantFuture) < ($1.priority, $1.targetDay ?? .distantFuture)
        }
    }

    /// The plan in use today, if there is one.
    private var currentPlan: TrainingPlan? {
        plans.first {
            !$0.isDraft && calendar.startOfDay(for: $0.startDay) <= today
                && today <= calendar.startOfDay(for: $0.endDay)
        }
    }

    private var lastSevenDays: [CompletedWorkout] {
        let cutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        return workouts.filter { $0.start >= cutoff && $0.isPrimary }
    }

    /// Daily load back far enough to cover the weekly chart.
    private var loadDays: [LoadDay] {
        let start = calendar.date(byAdding: .day, value: -(Self.weeklyChartWeeks * 7 - 1), to: today) ?? today
        return LoadTrend.days(workouts.compactMap(\.loadEntry), from: start, to: today, calendar: calendar)
    }

    private func baseline(_ value: KeyPath<DailyMetrics, Double?>, _ direction: RecoveryDirection) -> [BaselinePoint] {
        let readings = days.compactMap { day in day[keyPath: value].map { (date: day.day, value: $0) } }
        let cutoff = calendar.date(byAdding: .day, value: -(Self.recoveryDays - 1), to: today) ?? today
        return RecoveryBaseline.points(readings, direction: direction, calendar: calendar).filter { $0.date >= cutoff }
    }

    var body: some View {
        let loadDays = loadDays
        let hrv = baseline(\.hrvSDNN, .lowIsWorse)
        let restingHR = baseline(\.restingHR, .highIsWorse)
        let sleep = baseline(\.sleepSeconds, .lowIsWorse)
        let flags = flags(load: loadDays.last, hrv: hrv, restingHR: restingHR, sleep: sleep)

        List {
            if environment.healthState == .needsAuthorization {
                connectSection
            }

            if environment.healthState == .failed {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Couldn't read Apple Health")
                            Text("What you see may be out of date.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Try Again") {
                        Task { await environment.syncHealth(force: true) }
                    }
                }
            }

            if let goal = headlineGoal {
                Section {
                    Button {
                        isShowingGoals = true
                    } label: {
                        GoalHeadline(goal: goal, others: upcomingGoals.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !flags.isEmpty {
                Section("Heads up") {
                    ForEach(flags) { flag in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(flag.title)
                                Text(flag.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }

            if !plannedToday.isEmpty || currentPlan != nil {
                Section {
                    if plannedToday.isEmpty {
                        Label("Nothing planned today", systemImage: "calendar")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(plannedToday) { workout in
                        if workout.isDayMarker {
                            TodaySessionCard(workout: workout)
                        } else {
                            NavigationLink {
                                PlannedWorkoutDetailView(workout: workout)
                            } label: {
                                TodaySessionCard(workout: workout)
                            }
                        }
                    }
                } header: {
                    Text(todayHeader)
                }
            }

            if let plan = currentPlan {
                let week = PlanCalendar.weekDays(containing: today, calendar: calendar)
                let compliance = plan.compliance(on: week)
                if compliance.planned > 0 {
                    Section {
                        Button {
                            selection = .plan
                        } label: {
                            WeekStrip(plan: plan, days: week)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the plan")
                    } header: {
                        Text("This week · \(compliance.completed) of \(compliance.planned) done")
                    }
                }
            }

            if loadDays.contains(where: { $0.total > 0 }) {
                loadSection(loadDays)
            }

            Section {
                if workouts.isEmpty, let waiting = waitingText {
                    // The banner says what is happening; this says what to expect.
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(waiting).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if workouts.isEmpty {
                    Text(
                        environment.healthSource == nil
                            ? "No workouts yet. They arrive from your iPhone through iCloud."
                            : "No workouts yet."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        TrendsView(
                            weeks: WeekLoad.weeks(from: loadDays, calendar: calendar),
                            lastSevenDays: lastSevenDays, hrv: hrv, restingHR: restingHR, sleep: sleep)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Trends")
                                Text("Load by sport, the last 7 days, recovery")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "chart.xyaxis.line")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingGoals) {
            UpcomingGoalsSheet(goals: upcomingGoals)
        }
        .readableWidth(820)
        #if os(iOS)
        // The Mac has its Settings window in the app menu instead.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                OpenSettingsButton {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        #endif
    }

    private var todayHeader: String {
        var parts = [today.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        if let phase = currentPlan?.phase(on: today) { parts.append("\(phase.kind.displayName) phase") }
        return parts.joined(separator: " · ")
    }

    /// What an empty dashboard is waiting on, if anything is actually in progress.
    private var waitingText: String? {
        if environment.healthState == .syncing {
            return
                "Your workouts will appear here. The first import reads your last 90 days and can take a minute or two; you can keep using the app."
        }
        if environment.isImportingFromICloud {
            return
                "Your workouts will appear here. They are read on your iPhone and arrive through iCloud, which can take a few minutes the first time."
        }
        return nil
    }

    private var connectSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connect Apple Health", systemImage: "heart.text.square")
                    .font(.headline)
                Text(
                    "Long Game reads your workouts and recovery data to compare them with your plan. It never writes to Health."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Button("Connect") {
                    Task { await environment.connectHealth() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func loadSection(_ loadDays: [LoadDay]) -> some View {
        let latest = loadDays.last
        Section {
            HStack(alignment: .top) {
                StatTile(title: "7-day load", value: Format.load((latest?.acute ?? 0) * 7))
                StatTile(title: "4-week average", value: Format.load((latest?.chronic ?? 0) * 7), caption: "per week")
                StatTile(
                    title: "Load ratio",
                    value: latest?.ratio.map(Format.ratio) ?? "–",
                    caption: ratioCaption(latest),
                    isFlagged: latest?.isRatioFlagged ?? false
                )
            }
            .padding(.vertical, 4)
            LoadTrendChart(days: Array(loadDays.suffix(Self.trendDays)))
        } header: {
            Text("Training load")
        } footer: {
            Text(
                "Load is minutes weighted by heart-rate zone, or by power for rides when FTP is set. The ratio compares the last 7 days with the last 28; \(Format.ratio(AnalysisConstants.loadRatioRange.lowerBound))–\(Format.ratio(AnalysisConstants.loadRatioRange.upperBound)) is the steady range."
            )
        }
    }

    private func ratioCaption(_ day: LoadDay?) -> String {
        guard let ratio = day?.ratio else { return "needs 4 weeks" }
        if ratio > AnalysisConstants.loadRatioRange.upperBound { return "ramping fast" }
        if ratio < AnalysisConstants.loadRatioRange.lowerBound { return "dropping" }
        return "steady"
    }

    // MARK: Flags

    private struct Flag: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    /// Load and recovery concerns for today. A recovery reading only counts if it is recent.
    private func flags(load: LoadDay?, hrv: [BaselinePoint], restingHR: [BaselinePoint], sleep: [BaselinePoint])
        -> [Flag]
    {
        var flags: [Flag] = []
        if let load, let ratio = load.ratio, load.isRatioFlagged {
            let rising = ratio > AnalysisConstants.loadRatioRange.upperBound
            flags.append(
                Flag(
                    id: "load",
                    title: rising ? "Training load is ramping fast" : "Training load has dropped",
                    detail: "The last 7 days are \(Format.ratio(ratio))× your 4-week average."
                ))
        }
        let recent = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        func check(_ id: String, _ points: [BaselinePoint], _ title: String, _ format: (Double) -> String) {
            guard let latest = points.last, latest.isFlagged, latest.date >= recent, let mean = latest.mean else {
                return
            }
            flags.append(Flag(id: id, title: title, detail: "\(format(latest.value)) against a usual \(format(mean))."))
        }
        check("hrv", hrv, "HRV is below your normal range") { "\(Format.load($0)) ms" }
        check("rhr", restingHR, "Resting heart rate is above your normal range", Format.heartRate)
        check("sleep", sleep, "Sleep was shorter than usual", Format.duration)
        return flags
    }
}

/// The goal the athlete is building toward, on one line. Tapping it lists every goal ahead.
private struct GoalHeadline: View {
    let goal: Goal
    let others: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.checkered").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if others > 0 {
                    Text("and \(others) more goal\(others == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let days = goal.daysAway {
                Text("\(days) day\(days == 1 ? "" : "s")")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows all your goals")
    }
}

/// Every goal still ahead with its countdown.
private struct UpcomingGoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goals: [Goal]

    var body: some View {
        NavigationStack {
            List(goals) { goal in
                GoalCountdownRow(goal: goal)
            }
            .navigationTitle("Goals")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

private struct GoalCountdownRow: View {
    let goal: Goal

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.title).font(.headline)
                HStack(spacing: 6) {
                    Text("\(goal.priority.rawValue) goal")
                    if let date = goal.targetDay {
                        Text("·")
                        Text(date.formatted(date: .long, time: .omitted))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let days = goal.daysAway {
                VStack(alignment: .trailing) {
                    Text(days.formatted()).font(.title.bold()).monospacedDigit()
                    Text(days == 1 ? "day" : "days").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension Goal {
    fileprivate var daysAway: Int? {
        guard let targetDate = targetDay else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: targetDate)
        ).day
    }
}

/// One of today's sessions, given room: what it asks for, its shape, and how it went.
private struct TodaySessionCard: View {
    let workout: PlannedWorkout

    private var summary: String {
        let targets = Format.targets(of: workout)
        guard let matched = workout.matchedWorkout, let seconds = workout.targetDurationSeconds else {
            return targets
        }
        var parts = ["\(Format.duration(seconds)) planned", "\(Format.duration(matched.durationSeconds)) done"]
        if !workout.targetIntensity.isEmpty { parts.append(workout.targetIntensity) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: workout.symbolName)
                .font(.title3)
                .foregroundStyle(workout.tintColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.title(of: workout)).font(.headline)
                    Spacer(minLength: 8)
                    StatusChip(workout: workout)
                }
                if !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                if let structure = workout.structure {
                    WorkoutProfileChart(segments: structure.profile(sport: workout.sport), isCompact: true)
                        .frame(maxWidth: 260)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The week at a glance: one column per day, a mark for how each day went.
private struct WeekStrip: View {
    let plan: TrainingPlan
    let days: [Date]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                VStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    mark(for: day)
                        .frame(width: 18, height: 18)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isToday { RoundedRectangle(cornerRadius: 8).fill(.tint.opacity(0.12)) }
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week")
        .accessibilityValue(days.map(description).joined(separator: "; "))
    }

    private func sessions(on day: Date) -> [PlannedWorkout] {
        plan.workouts(on: day).filter { !$0.isDayMarker }
    }

    @ViewBuilder
    private func mark(for day: Date) -> some View {
        let statuses = sessions(on: day).map(\.status)
        if statuses.isEmpty {
            Image(systemName: "minus").foregroundStyle(.tertiary)
        } else if statuses.contains(where: { $0 == .missed || $0 == .skipped }) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if statuses.contains(.partial) {
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
        } else if statuses.allSatisfy({ $0 == .done || $0 == .overdone }) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func description(of day: Date) -> String {
        let sessions = sessions(on: day)
        let name = day.formatted(.dateTime.weekday(.wide))
        guard !sessions.isEmpty else { return "\(name), nothing planned" }
        return "\(name), " + sessions.map { "\(Format.title(of: $0)) \($0.status.label)" }.joined(separator: ", ")
    }
}
