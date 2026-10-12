import Analysis
import Models
import SwiftUI

struct PlanWeekView: View {
    let plan: TrainingPlan
    @Binding var anchor: Date
    @Binding var sheet: PlanSheet?

    private var days: [Date] { PlanCalendar.weekDays(containing: anchor, calendar: .current) }

    private var title: String {
        guard let first = days.first, let last = days.last else { return "" }
        return (first..<last).formatted(.interval.day().month(.abbreviated))
    }

    private var plannedSeconds: Double {
        days.flatMap { plan.workouts(on: $0) }.reduce(0) { $0 + ($1.targetDurationSeconds ?? 0) }
    }

    var body: some View {
        ScrollView {
            // One column on a phone; side by side where there is room.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading,
                spacing: 12
            ) {
                ForEach(days, id: \.self) { day in
                    DayCard(plan: plan, day: day, sheet: $sheet)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
        }
        // The week and its progress stay put while the days scroll underneath.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                PeriodHeader(
                    title: title,
                    subtitle: subtitle,
                    step: { shift(weeks: $0) },
                    today: { withAnimation { anchor = .now } }
                )
                // A draft has not been trained against, so it has no compliance to show.
                if !plan.isDraft {
                    WeekComplianceSummary(compliance: plan.compliance(on: days))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    /// The phase of the selected day, which is also what the month view names.
    private var subtitle: String {
        var parts: [String] = []
        if let phase = plan.phase(on: anchor) { parts.append("\(phase.kind.displayName) phase") }
        if plannedSeconds > 0 { parts.append("\(Format.duration(plannedSeconds)) planned") }
        return parts.joined(separator: " · ")
    }

    private func shift(weeks: Int) {
        guard let date = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: anchor) else { return }
        withAnimation { anchor = date }
    }
}

private struct DayCard: View {
    let plan: TrainingPlan
    let day: Date
    @Binding var sheet: PlanSheet?
    @State private var isTargeted = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isPast: Bool { day < Calendar.current.startOfDay(for: .now) }

    var body: some View {
        let workouts = plan.workouts(on: day)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isToday ? "Today · \(dayTitle)" : dayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Spacer()
                AddToDayMenu(plan: plan, day: day, sheet: $sheet)
                    .frame(minWidth: 44, minHeight: 32)
                    .contentShape(.rect)
            }
            ForEach(workouts) { workout in
                PlannedWorkoutRow(workout: workout, sheet: $sheet)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.cardBackground, in: .rect(cornerRadius: 16))
        // Days already behind step back so the eye lands on today and what is ahead.
        .opacity(isPast && !plan.isDraft ? 0.72 : 1)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2)
            } else if isToday {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint.opacity(0.7), lineWidth: 1.5)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            withAnimation { ids.contains { plan.moveWorkout(withID: $0, to: day) } }
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
