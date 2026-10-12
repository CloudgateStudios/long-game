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

    private static let trendDays = 42
    private static let weeklyChartWeeks = 8
    private static let recoveryDays = 28

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: .now) }

    private var plannedToday: [PlannedWorkout] {
        planned.filter { calendar.isDateInToday($0.date) && $0.plan?.isDraft != true }
    }

    private var nextGoal: Goal? {
        goals
            .filter { $0.status == .active && ($0.targetDate ?? .distantPast) >= today }
            .min { ($0.priority, $0.targetDate ?? .distantFuture) < ($1.priority, $1.targetDate ?? .distantFuture) }
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
        let readings = days.compactMap { day in day[keyPath: value].map { (date: day.date, value: $0) } }
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

            if let goal = nextGoal {
                Section("Next goal") {
                    GoalCountdownRow(goal: goal)
                }
            }

            if !plannedToday.isEmpty {
                Section("Planned today") {
                    ForEach(plannedToday) { workout in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Format.title(of: workout))
                                let targets = Format.targets(of: workout)
                                if !targets.isEmpty {
                                    Text(targets).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: workout.symbolName)
                        }
                        .badge(workout.status == .planned ? nil : Text(workout.status.label))
                    }
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

            if loadDays.contains(where: { $0.total > 0 }) {
                loadSection(loadDays)
            }

            Section("Last 7 days") {
                if workouts.isEmpty, let waiting = waitingText {
                    // The banner says what is happening; this says what to expect.
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(waiting).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if lastSevenDays.isEmpty {
                    Text(
                        environment.healthSource == nil && workouts.isEmpty
                            ? "No workouts yet. They arrive from your iPhone through iCloud."
                            : "No workouts in the last 7 days."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    sportTable
                }
            }

            // Recovery signals are optional: a denied Health permission just leaves them empty.
            if !hrv.isEmpty || !restingHR.isEmpty || !sleep.isEmpty {
                Section {
                    if !hrv.isEmpty {
                        RecoveryChart(title: "HRV", points: hrv) { "\(Format.load($0)) ms" }
                    }
                    if !restingHR.isEmpty {
                        RecoveryChart(title: "Resting heart rate", points: restingHR, format: Format.heartRate)
                    }
                    if !sleep.isEmpty {
                        RecoveryChart(title: "Sleep (hours)", points: sleep, axisDivisor: 3600, format: Format.duration)
                    }
                } header: {
                    Text("Recovery · last 4 weeks")
                } footer: {
                    Text(
                        "The shaded band is your normal range: the average of the previous 28 days, give or take one standard deviation. Diamonds mark days on the wrong side of it."
                    )
                }
            }
        }
        .readableWidth(820)
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

        Section("Weekly load by sport") {
            WeeklyLoadChart(weeks: WeekLoad.weeks(from: loadDays, calendar: calendar))
        }
    }

    private func ratioCaption(_ day: LoadDay?) -> String {
        guard let ratio = day?.ratio else { return "needs 4 weeks" }
        if ratio > AnalysisConstants.loadRatioRange.upperBound { return "ramping fast" }
        if ratio < AnalysisConstants.loadRatioRange.lowerBound { return "dropping" }
        return "steady"
    }

    /// The numbers behind the charts, by sport, so nothing depends on telling colors apart.
    private var sportTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Sport").gridColumnAlignment(.leading)
                Text("Sessions")
                Text("Time")
                Text("Load")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(Sport.allCases) { sport in
                let matching = lastSevenDays.filter { $0.sport == sport }
                if !matching.isEmpty {
                    GridRow {
                        Label {
                            Text(sport.displayName)
                        } icon: {
                            Image(systemName: sport.symbolName).foregroundStyle(sport.chartColor)
                        }
                        Text(matching.count.formatted())
                        Text(Format.duration(matching.reduce(0) { $0 + $1.durationSeconds }))
                        Text(Format.load(matching.reduce(0) { $0 + ($1.load ?? 0) }))
                    }
                    .monospacedDigit()
                }
            }
            Divider()
            GridRow {
                Text("Total").gridColumnAlignment(.leading)
                Text(lastSevenDays.count.formatted())
                Text(Format.duration(lastSevenDays.reduce(0) { $0 + $1.durationSeconds }))
                Text(Format.load(lastSevenDays.reduce(0) { $0 + ($1.load ?? 0) }))
            }
            .fontWeight(.semibold)
            .monospacedDigit()
        }
        .padding(.vertical, 4)
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

/// A headline number with a label, used in place of a chart for a single value.
private struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var isFlagged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            if let caption {
                HStack(spacing: 3) {
                    if isFlagged {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(caption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct GoalCountdownRow: View {
    let goal: Goal

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.title).font(.headline)
                if let date = goal.targetDate {
                    Text(date.formatted(date: .long, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let date = goal.targetDate, let days = daysUntil(date) {
                VStack(alignment: .trailing) {
                    Text(days.formatted()).font(.title.bold()).monospacedDigit()
                    Text(days == 1 ? "day" : "days").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func daysUntil(_ date: Date) -> Int? {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date))
            .day
    }
}
