import Analysis
import Charts
import SwiftUI

/// Small card shown above a chart's selected point. Text stays in ink colors; a swatch
/// beside it carries the series identity.
private struct ChartTooltip: View {
    let title: String
    let rows: [(color: Color?, label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    if let color = row.color {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    }
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.value).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 130)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

private func nearest<Element>(_ items: [Element], to date: Date?, by key: (Element) -> Date) -> Element? {
    guard let date else { return nil }
    return items.min { abs(key($0).timeIntervalSince(date)) < abs(key($1).timeIntervalSince(date)) }
}

/// Seven-day against 28-day average daily load. Both lines share one axis.
struct LoadTrendChart: View {
    let days: [LoadDay]
    @State private var selection: Date?

    private static let acute = "7-day average"
    private static let chronic = "28-day average"

    var body: some View {
        let selected = nearest(days, to: selection, by: \.date)
        Chart {
            ForEach(days) { day in
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Load", day.chronic), series: .value("Series", Self.chronic))
                    .foregroundStyle(by: .value("Series", Self.chronic))
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Load", day.acute), series: .value("Series", Self.acute))
                    .foregroundStyle(by: .value("Series", Self.acute))
            }
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if let selected {
                RuleMark(x: .value("Day", selected.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: selected.date.formatted(.dateTime.weekday().day().month()), rows: [
                            (.series1, Self.acute, Format.load(selected.acute)),
                            (.series2, Self.chronic, Format.load(selected.chronic)),
                            (nil, "Ratio", selected.ratio.map(Format.ratio) ?? "–"),
                        ])
                    }
            }
        }
        .chartForegroundStyleScale([Self.acute: Color.series1, Self.chronic: Color.series2])
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 190)
        .accessibilityLabel("Average daily training load, last 7 days against last 28 days")
    }
}

struct WeekLoad: Identifiable {
    let start: Date
    var bySport: [Sport: Double] = [:]

    var id: Date { start }
    var total: Double { bySport.values.reduce(0, +) }

    static func weeks(from days: [LoadDay], calendar: Calendar) -> [WeekLoad] {
        var weeks: [Date: WeekLoad] = [:]
        for day in days {
            let start = calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
            for (sport, load) in day.bySport {
                weeks[start, default: WeekLoad(start: start)].bySport[sport, default: 0] += load
            }
            if weeks[start] == nil { weeks[start] = WeekLoad(start: start) }
        }
        return weeks.values.sorted { $0.start < $1.start }
    }
}

/// Weekly load stacked by sport.
struct WeeklyLoadChart: View {
    let weeks: [WeekLoad]
    @State private var selection: Date?

    var body: some View {
        // A tap lands anywhere in the bar's week, so match on the week it falls in.
        let selected = selection.flatMap { date in weeks.last { $0.start <= date } }
        Chart {
            ForEach(weeks) { week in
                ForEach(Sport.allCases) { sport in
                    if let load = week.bySport[sport], load > 0 {
                        BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Load", load), width: .ratio(0.62))
                            .foregroundStyle(by: .value("Sport", sport.displayName))
                            .cornerRadius(3)
                    }
                }
            }
            if let selected {
                RuleMark(x: .value("Week", selected.start, unit: .weekOfYear))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(
                            title: "Week of \(selected.start.formatted(.dateTime.day().month()))",
                            rows: Sport.allCases.compactMap { sport in
                                selected.bySport[sport].map { (sport.chartColor, sport.displayName, Format.load($0)) }
                            } + [(nil, "Total", Format.load(selected.total))]
                        )
                    }
            }
        }
        .chartForegroundStyleScale(domain: Sport.allCases.map(\.displayName), range: Sport.allCases.map(\.chartColor))
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                // Numeric dates: one label per bar has to fit on a phone.
                AxisValueLabel(format: .dateTime.day().month(.defaultDigits), centered: true)
            }
        }
        .frame(height: 210)
        .accessibilityLabel("Weekly training load by sport")
    }
}

/// One recovery signal against its rolling normal range (mean ± one standard deviation).
struct RecoveryChart: View {
    let title: String
    let points: [BaselinePoint]
    /// Divides plotted values so the axis reads in a sensible unit (hours for sleep).
    var axisDivisor = 1.0
    let format: (Double) -> String
    @State private var selection: Date?

    var body: some View {
        let selected = nearest(points, to: selection, by: \.date)
        VStack(alignment: .leading, spacing: 6) {
            header
            Chart {
                ForEach(points) { point in
                    if let mean = point.mean, let deviation = point.deviation {
                        AreaMark(
                            x: .value("Day", point.date, unit: .day),
                            yStart: .value("Low", (mean - deviation) / axisDivisor),
                            yEnd: .value("High", (mean + deviation) / axisDivisor)
                        )
                        .foregroundStyle(.gray.opacity(0.18))
                    }
                }
                ForEach(points) { point in
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value / axisDivisor))
                        .foregroundStyle(Color.series1)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                // Days outside the normal range get a marker as well as a color.
                ForEach(points.filter(\.isFlagged)) { point in
                    PointMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value / axisDivisor))
                        .symbol(.diamond)
                        .symbolSize(70)
                        .foregroundStyle(.orange)
                }
                if let selected {
                    RuleMark(x: .value("Day", selected.date, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTooltip(title: selected.date.formatted(.dateTime.weekday().day().month()), rows: [
                                (.series1, title, format(selected.value)),
                                (nil, "Normal", normalRange(of: selected) ?? "–"),
                            ])
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXSelection(value: $selection)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 130)
            .accessibilityLabel("\(title), last 4 weeks, with normal range")
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let latest = points.last {
                Text(format(latest.value)).font(.subheadline).monospacedDigit()
                if latest.isFlagged {
                    Label("Outside normal", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func normalRange(of point: BaselinePoint) -> String? {
        guard let mean = point.mean, let deviation = point.deviation else { return nil }
        return "\(format(mean - deviation)) – \(format(mean + deviation))"
    }
}
