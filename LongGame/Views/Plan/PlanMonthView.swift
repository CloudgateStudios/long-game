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
                PeriodHeader(
                    title: anchor.formatted(.dateTime.month(.wide).year()),
                    subtitle: plan.phase(on: anchor).map { "\($0.kind.displayName) phase" } ?? "",
                    step: { shift(months: $0) },
                    today: { withAnimation { anchor = .now } }
                )

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(PlanCalendar.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                        Text(symbol).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                        if let day {
                            MonthCell(
                                plan: plan,
                                day: day,
                                height: cellHeight,
                                isSelected: calendar.isDate(day, inSameDayAs: anchor),
                                select: { anchor = day }
                            )
                        } else {
                            Color.clear.frame(height: cellHeight)
                        }
                    }
                }

                selectedDay
            }
            .padding(.horizontal)
            .padding(.bottom)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var selectedDay: some View {
        let workouts = plan.workouts(on: anchor)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(anchor.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Session", systemImage: "plus") { sheet = .newWorkout(anchor) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
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
    let select: () -> Void
    @State private var isTargeted = false

    var body: some View {
        let workouts = plan.workouts(on: day)
        let isToday = Calendar.current.isDateInToday(day)
        Button(action: select) {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                HStack(spacing: 2) {
                    ForEach(workouts.prefix(3)) { workout in
                        Image(systemName: workout.sessionType == .rest ? "moon.zzz" : workout.sport.symbolName)
                            .font(.caption2)
                            .imageScale(.small)
                            .foregroundStyle(workout.status.color)
                    }
                    if workouts.count > 3 {
                        Text("+").font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.cardBackground), in: .rect(cornerRadius: 10))
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(workouts.isEmpty ? "Nothing planned" : workouts.map { "\(Format.title(of: $0)), \($0.status.label)" }.joined(separator: "; "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .dropDestination(for: String.self) { ids, _ in
            withAnimation { ids.contains { plan.moveWorkout(withID: $0, to: day) } }
        } isTargeted: {
            isTargeted = $0
        }
    }
}
