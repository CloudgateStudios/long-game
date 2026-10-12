import Analysis
import Models
import SwiftUI

struct PlanMonthView: View {
    let plan: TrainingPlan
    /// The selected day; the grid shows its month.
    @Binding var anchor: Date
    @Binding var sheet: PlanSheet?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    /// Grows with the text size so day numbers and icons are never clipped.
    @ScaledMetric(relativeTo: .callout) private var cellHeight: CGFloat = 54

    var body: some View {
        let calendar = Calendar.current
        let cells = PlanCalendar.monthGrid(containing: anchor, calendar: calendar)
        ScrollView {
            VStack(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(PlanCalendar.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) {
                        _, symbol in
                        Text(symbol).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                        if let day {
                            MonthCell(
                                plan: plan,
                                day: day,
                                height: cellHeight,
                                isSelected: calendar.isDate(day, inSameDayAs: anchor),
                                isAlternatePhase: phaseIndex(on: day).map { !$0.isMultiple(of: 2) },
                                select: { anchor = day }
                            )
                        } else {
                            Color.clear.frame(height: cellHeight)
                        }
                    }
                }

                let phases = phaseSummary(for: cells.compactMap { $0 })
                if !phases.isEmpty {
                    Text(phases)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                selectedDay
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PeriodHeader(
                title: anchor.formatted(.dateTime.month(.wide).year()),
                subtitle: plan.phase(on: anchor).map { "\($0.kind.displayName) phase" } ?? "",
                step: { shift(months: $0) },
                today: { withAnimation { anchor = .now } }
            )
            .padding(.horizontal)
            .padding(.bottom, 6)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func phaseIndex(on day: Date) -> Int? {
        guard let phase = plan.phase(on: day) else { return nil }
        return plan.sortedPhases.firstIndex { $0 === phase }
    }

    /// Which phases the month on screen runs through, in words, to go with the bands.
    private func phaseSummary(for days: [Date]) -> String {
        var seen: [PlanPhase] = []
        for day in days {
            if let phase = plan.phase(on: day), !seen.contains(where: { $0 === phase }) { seen.append(phase) }
        }
        guard seen.count > 1 else { return "" }
        return seen.enumerated().map { index, phase in
            index == 0
                ? phase.kind.displayName
                : "\(phase.kind.displayName) from \(phase.startDate.formatted(.dateTime.day().month(.abbreviated)))"
        }
        .joined(separator: " · ")
    }

    private var selectedDay: some View {
        let workouts = plan.workouts(on: anchor)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(anchor.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                AddToDayMenu(plan: plan, day: anchor, sheet: $sheet)
            }
            if workouts.isEmpty {
                Text("Nothing planned").foregroundStyle(.secondary)
            }
            ForEach(workouts) { workout in
                PlannedWorkoutRow(workout: workout, sheet: $sheet)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.cardBackground, in: .rect(cornerRadius: 16))
    }

    private func shift(months: Int) {
        guard let date = Calendar.current.date(byAdding: .month, value: months, to: anchor) else { return }
        withAnimation { anchor = date }
    }
}

private struct MonthCell: View {
    let plan: TrainingPlan
    let day: Date
    let height: CGFloat
    let isSelected: Bool
    /// Nil outside any phase; otherwise alternates from one phase to the next so the
    /// band along the bottom of the cells changes where the phase does.
    let isAlternatePhase: Bool?
    let select: () -> Void
    @State private var isTargeted = false

    /// One mark for the day's outcome. Nothing while every session is still ahead.
    private func outcome(of sessions: [PlannedWorkout]) -> (symbol: String, color: Color)? {
        let statuses = sessions.map(\.status)
        if statuses.contains(where: { $0 == .missed || $0 == .skipped }) { return ("xmark.circle.fill", .red) }
        if statuses.contains(.partial) { return ("circle.lefthalf.filled", .orange) }
        if !statuses.isEmpty, statuses.allSatisfy({ $0 == .done || $0 == .overdone }) {
            return ("checkmark.circle.fill", .green)
        }
        return nil
    }

    var body: some View {
        let workouts = plan.workouts(on: day)
        let sessions = workouts.filter { !$0.isDayMarker }
        let marker = workouts.first(where: \.isDayMarker)
        let isToday = Calendar.current.isDateInToday(day)
        Button(action: select) {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 5)
                    .background {
                        if isToday { Capsule().fill(.tint) }
                    }
                // Color says which sport; the mark in the corner says how the day went.
                HStack(spacing: 3) {
                    ForEach(sessions.prefix(3)) { workout in
                        Circle().fill(workout.tintColor).frame(width: 6, height: 6)
                    }
                    if sessions.count > 3 {
                        Text("+").font(.caption2)
                    }
                    if sessions.isEmpty, let marker {
                        Image(systemName: marker.symbolName).font(.caption2).imageScale(.small)
                    }
                }
                .frame(height: 8)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.cardBackground),
                in: .rect(cornerRadius: 10)
            )
            .overlay(alignment: .topTrailing) {
                if let outcome = outcome(of: sessions) {
                    Image(systemName: outcome.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(outcome.color)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                if let isAlternatePhase {
                    Rectangle()
                        .fill(
                            isAlternatePhase
                                ? AnyShapeStyle(.tint.opacity(0.55)) : AnyShapeStyle(.secondary.opacity(0.35))
                        )
                        .frame(height: 3)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(
            workouts.isEmpty
                ? "Nothing planned"
                : workouts.map { "\(Format.title(of: $0)), \($0.status.label)" }.joined(separator: "; ")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .dropDestination(for: String.self) { ids, _ in
            withAnimation { ids.contains { plan.moveWorkout(withID: $0, to: day) } }
        } isTargeted: {
            isTargeted = $0
        }
    }
}
