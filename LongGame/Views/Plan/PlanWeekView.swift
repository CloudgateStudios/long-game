import Analysis
import Models
import SwiftUI

struct PlanWeekView: View {
    /// Nil when there is no plan: the week then shows only what was done.
    let plan: TrainingPlan?
    var log = WorkoutLog()
    @Binding var anchor: Date
    @Binding var sheet: PlanSheet?

    private var days: [Date] { PlanCalendar.weekDays(containing: anchor, calendar: .current) }

    private var title: String {
        guard let first = days.first, let last = days.last else { return "" }
        return (first..<last).formatted(.interval.day().month(.abbreviated))
    }

    private var plannedSeconds: Double {
        days.flatMap { plan?.workouts(on: $0) ?? [] }.reduce(0) { $0 + ($1.targetDurationSeconds ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The week and its progress stay put while the weeks slide underneath.
            VStack(alignment: .leading, spacing: 8) {
                PeriodHeader(
                    title: title,
                    subtitle: subtitle,
                    step: { shift(weeks: $0) },
                    today: { withAnimation { anchor = .now } }
                )
                // A draft has not been trained against, so it has no compliance to show.
                if let plan, !plan.isDraft {
                    WeekComplianceSummary(compliance: plan.compliance(on: days))
                }
                if let done {
                    Text(done).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
            .background(.bar)

            PeriodPager(unit: .weekOfYear, anchor: $anchor) { start in
                WeekPage(
                    plan: plan, log: log, days: PlanCalendar.weekDays(containing: start, calendar: .current),
                    sheet: $sheet)
            }
        }
    }

    /// The phase of the selected day, which is also what the month view names.
    private var subtitle: String {
        var parts: [String] = []
        if let phase = plan?.phase(on: anchor) { parts.append("\(phase.kind.displayName) phase") }
        if plannedSeconds > 0 { parts.append("\(Format.duration(plannedSeconds)) planned") }
        if parts.isEmpty, plan.map({ plan in !days.contains { plan.covers($0) } }) ?? true {
            return "No plan this week"
        }
        return parts.joined(separator: " · ")
    }

    /// What the week added up to, and how much of it nothing in the plan asked for.
    private var done: String? {
        let totals = log.totals(on: days)
        guard totals.count > 0 else { return nil }
        var parts = ["\(Format.duration(totals.seconds)) done", "\(Format.load(totals.load)) load"]
        if let plan {
            let extras = days.filter { plan.covers($0) }.flatMap { log.extras(on: $0, beyond: plan) }
                .count { $0.workout.isPrimary && $0.workout.plannedWorkout == nil }
            if extras > 0 { parts.append("\(extras) extra") }
        }
        return parts.joined(separator: " · ")
    }

    private func shift(weeks: Int) {
        guard let date = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: anchor) else { return }
        withAnimation { anchor = date }
    }
}

private struct WeekPage: View {
    let plan: TrainingPlan?
    let log: WorkoutLog
    let days: [Date]
    @Binding var sheet: PlanSheet?

    /// With no plan there is nothing to add to an empty day, so only days with workouts show.
    private var shownDays: [Date] {
        plan == nil ? days.filter { !log.entries(on: $0).isEmpty } : days
    }

    var body: some View {
        ScrollView {
            // One column on a phone; side by side where there is room.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading,
                spacing: 12
            ) {
                ForEach(shownDays, id: \.self) { day in
                    DayCard(plan: plan, log: log, day: day, sheet: $sheet)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
            if shownDays.isEmpty {
                Text("No workouts this week").foregroundStyle(.secondary).padding(.top, 40)
            }
        }
    }
}

private struct DayCard: View {
    let plan: TrainingPlan?
    let log: WorkoutLog
    let day: Date
    @Binding var sheet: PlanSheet?
    @State private var isTargeted = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isPast: Bool { day < Calendar.current.startOfDay(for: .now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isToday ? "Today · \(dayTitle)" : dayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Spacer()
                if let plan {
                    AddToDayMenu(plan: plan, day: day, sheet: $sheet)
                        .frame(minWidth: 44, minHeight: 32)
                        .contentShape(.rect)
                }
            }
            DayRows(plan: plan, day: day, log: log, sheet: $sheet)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.cardBackground, in: .rect(cornerRadius: 16))
        // Days already behind step back so the eye lands on today and what is ahead.
        .opacity(isPast && plan?.isDraft != true ? 0.72 : 1)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2)
            } else if isToday {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint.opacity(0.7), lineWidth: 1.5)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let plan else { return false }
            return withAnimation { ids.contains { plan.moveWorkout(withID: $0, to: day) } }
        } isTargeted: {
            isTargeted = $0
        }
    }

    private var dayTitle: String { day.formatted(.dateTime.weekday(.wide).day()) }
}

/// Sessions done and planned load achieved for the week on screen, as one bar and a line.
struct WeekComplianceSummary: View {
    let compliance: WeekCompliance

    var body: some View {
        if compliance.planned > 0 {
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: min(compliance.loadFraction ?? fractionDone, 1))
                    .accessibilityHidden(true)
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var fractionDone: Double { Double(compliance.completed) / Double(max(compliance.planned, 1)) }

    private var details: [String] {
        [
            "\(compliance.completed) of \(compliance.planned) done",
            compliance.loadFraction.map { "\(Format.percent($0)) of planned load" },
            compliance.partial > 0 ? "\(compliance.partial) partly done" : nil,
            compliance.missed > 0 ? "\(compliance.missed) missed" : nil,
        ].compactMap { $0 }
    }
}

/// Title with previous / next / today controls, shared by the week and month views.
struct PeriodHeader: View {
    let title: String
    let subtitle: String
    let step: (Int) -> Void
    let today: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Today", action: today)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Previous", systemImage: "chevron.left") { step(-1) }
                .labelStyle(.iconOnly)
                .frame(minWidth: 36, minHeight: 44)
                .contentShape(.rect)
            Button("Next", systemImage: "chevron.right") { step(1) }
                .labelStyle(.iconOnly)
                .frame(minWidth: 36, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonBorderShape(.capsule)
        .padding(.top, 4)
    }
}
