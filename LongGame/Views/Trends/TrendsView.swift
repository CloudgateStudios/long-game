import Analysis
import Models
import SwiftUI

/// The longer view behind Today: load by sport, the last week in numbers, and recovery.
struct TrendsView: View {
    let weeks: [WeekLoad]
    let lastSevenDays: [CompletedWorkout]
    let hrv: [BaselinePoint]
    let restingHR: [BaselinePoint]
    let sleep: [BaselinePoint]

    var body: some View {
        List {
            if weeks.contains(where: { $0.total > 0 }) {
                Section("Weekly load by sport") {
                    WeeklyLoadChart(weeks: weeks)
                }
            }

            Section("Last 7 days") {
                if lastSevenDays.isEmpty {
                    Text("No workouts in the last 7 days.").foregroundStyle(.secondary)
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
        .navigationTitle("Trends")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
}
