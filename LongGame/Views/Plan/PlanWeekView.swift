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
            LazyVStack(spacing: 12) {
                PeriodHeader(
                    title: title,
                    subtitle: subtitle,
                    step: { shift(weeks: $0) },
                    today: { withAnimation { anchor = .now } }
                )
                // A draft has not been trained against, so it has no compliance to show.
                if !plan.isDraft {
                    WeekComplianceCard(compliance: plan.compliance(on: days))
                }
                // One column on a phone; side by side where there is room.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(days, id: \.self) { day in
                        DayCard(plan: plan, day: day, sheet: $sheet)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let phase = days.first.flatMap({ plan.phase(on: $0) }) { parts.append("\(phase.kind.displayName) phase") }
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

    var body: some View {
        let workouts = plan.workouts(on: day)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide).day()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Spacer()
                Button("Add session on \(day.formatted(.dateTime.weekday(.wide)))", systemImage: "plus") {
                    sheet = .newWorkout(day)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
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
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            withAnimation { ids.contains { plan.moveWorkout(withID: $0, to: day) } }
        } isTargeted: {
            isTargeted = $0
        }
    }
}

/// Sessions done and planned load achieved for the week on screen.
private struct WeekComplianceCard: View {
    let compliance: WeekCompliance

    var body: some View {
        if compliance.planned > 0 {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(compliance.completed) of \(compliance.planned) sessions done")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let fraction = compliance.loadFraction {
                        Text("\(Format.percent(fraction)) of planned load")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let fraction = compliance.loadFraction {
                    ProgressView(value: min(fraction, 1))
                        .accessibilityHidden(true)
                }
                let details = [
                    compliance.partial > 0 ? "\(compliance.partial) partly done" : nil,
                    compliance.missed > 0 ? "\(compliance.missed) missed" : nil,
                    compliance.upcoming > 0 ? "\(compliance.upcoming) to go" : nil,
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.cardBackground, in: .rect(cornerRadius: 16))
        }
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
