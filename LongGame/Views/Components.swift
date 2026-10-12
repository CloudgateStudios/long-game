import Analysis
import Models
import SwiftUI

/// A small capsule label for a state or a category.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var isFilled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background {
                if isFilled {
                    Capsule().fill(tint.opacity(0.15))
                } else {
                    Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1)
                }
            }
            .fixedSize()
    }
}

/// How a planned session turned out, as one chip. Nothing is shown while it is still ahead.
struct StatusChip: View {
    let workout: PlannedWorkout

    var body: some View {
        if workout.status != .planned {
            Chip(text: workout.statusText, tint: workout.status.chipColor)
                .accessibilityLabel(workout.statusDescription)
        }
    }
}

extension PlannedStatus {
    /// Going over the target is still a session done, so it is not given a color of its own.
    var chipColor: Color {
        switch self {
        case .planned: .secondary
        case .done, .overdone: .green
        case .partial: .orange
        case .missed, .skipped: .red
        }
    }
}

extension PlannedWorkout {
    /// The sport's color, so a week reads by sport at a glance. Rest and flex days have none.
    var tintColor: Color { isDayMarker ? .secondary : sport.chartColor }

    /// "Done", "Done · 142%", "Partly · 60%", "Missed".
    var statusText: String {
        let name =
            switch status {
            case .done, .overdone: "Done"
            case .partial: "Partly"
            default: status.label
            }
        guard status != .done, let ratio = complianceRatio else { return name }
        return "\(name) · \(Format.percent(ratio))"
    }

    var statusDescription: String {
        guard let ratio = complianceRatio else { return status.label }
        return "\(status.label), \(Format.percent(ratio)) of target"
    }

    func move(byDays days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: date) else { return }
        withAnimation { self.date = date }
        try? modelContext?.save()
    }

    func duplicate(daysLater days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: date) else { return }
        let copy = PlannedWorkout(
            date: date,
            sport: sport,
            sessionType: sessionType,
            targetDurationSeconds: targetDurationSeconds,
            targetDistanceMeters: targetDistanceMeters,
            targetIntensity: targetIntensity,
            instructions: instructions
        )
        modelContext?.insert(copy)
        copy.plan = plan
        try? modelContext?.save()
    }
}

/// A headline number with a label, used in place of a chart for a single value.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var isFlagged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
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

/// Time in each heart-rate zone as one stacked bar, with the durations underneath.
struct ZoneBar: View {
    let seconds: [Double]

    private var total: Double { seconds.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(seconds.enumerated()), id: \.offset) { index, value in
                        if value > 0 {
                            Rectangle()
                                .fill(ProfileChart.color(zone: index + 1))
                                .frame(width: max(geometry.size.width * value / max(total, 1) - 1, 1))
                        }
                    }
                }
            }
            .frame(height: 12)
            .clipShape(.rect(cornerRadius: 4))
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(seconds.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 1) {
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(ProfileChart.color(zone: index + 1))
                                .frame(width: 8, height: 8)
                            Text("Z\(index + 1)").foregroundStyle(.secondary)
                        }
                        Text(Format.duration(value)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time in heart-rate zones")
        .accessibilityValue(
            seconds.enumerated().map { "Zone \($0.offset + 1), \(Format.duration($0.element))" }
                .joined(separator: "; "))
    }
}
