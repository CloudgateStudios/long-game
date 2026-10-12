import Analysis
import SwiftUI

/// A structured workout drawn as a row of bars: width is how long a step lasts, height
/// and colour how hard it is. The compact form is a thumbnail for calendar rows.
struct WorkoutProfileChart: View {
    let segments: [StructuredWorkout.Segment]
    var isCompact = false
    var paceUnit: StructuredWorkout.PaceUnit = .perKilometer

    @State private var selection: Int?

    private var total: Double { segments.reduce(0) { $0 + $1.seconds } }
    /// Headroom above threshold so an easy session does not fill the chart.
    private var ceiling: Double { max(segments.map(\.intensity).max() ?? 1, ProfileChart.minimumCeiling) }

    var body: some View {
        if isCompact {
            bars.frame(height: ProfileChart.compactHeight).accessibilityHidden(true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                bars.frame(height: ProfileChart.height)
                HStack {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if selection == nil { ZoneLegend() }
                }
                .frame(minHeight: 16)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workout profile")
            .accessibilityValue(accessibilitySummary)
        }
    }

    private var bars: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let gap = isCompact ? 0.5 : 1.0
            ZStack(alignment: .bottomLeading) {
                if !isCompact {
                    // Threshold, so the height of a bar can be read against something.
                    Path { path in
                        let y = size.height * (1 - 1 / ceiling)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let width = max(size.width * segment.seconds / max(total, 1) - gap, 1)
                    let height = max(size.height * segment.intensity / ceiling, 2)
                    UnevenRoundedRectangle(topLeadingRadius: isCompact ? 1 : 2, topTrailingRadius: isCompact ? 1 : 2)
                        .fill(ProfileChart.color(zone: segment.zone))
                        // A step whose length is a guess is drawn fainter.
                        .opacity((segment.isTimed ? 1 : 0.45) * (selection == nil || selection == index ? 1 : 0.35))
                        .frame(width: width, height: height)
                        .offset(x: size.width * segment.start / max(total, 1))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            .contentShape(.rect)
            .gesture(isCompact ? nil : select(width: size.width))
        }
    }

    /// Tap a bar to read off its step; tap it again to go back to the legend. A tap
    /// rather than a drag, so the chart never gets in the way of scrolling.
    private func select(width: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let time = Double(value.location.x / max(width, 1)) * total
                let tapped = segments.lastIndex { $0.start <= time } ?? 0
                selection = selection == tapped ? nil : tapped
            }
    }

    private var caption: String {
        if let selection, segments.indices.contains(selection) {
            let segment = segments[selection]
            var parts = [segment.kind.displayName, segment.step.lengthText]
            if let target = segment.step.target { parts.append(target.text(.init(paceUnit: paceUnit))) }
            return parts.joined(separator: " · ")
        }
        return segments.allSatisfy(\.isTimed) ? Format.duration(total) : "Length depends on your pace"
    }

    private var accessibilitySummary: String {
        let seconds = (1...5).map { zone in segments.filter { $0.zone == zone }.reduce(0) { $0 + $1.seconds } }
        let parts = seconds.enumerated().filter { $0.element > 0 }.map {
            "\(Format.duration($0.element)) in zone \($0.offset + 1)"
        }
        return "\(segments.count) steps. " + parts.joined(separator: ", ")
    }
}

private struct ZoneLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { zone in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(ProfileChart.color(zone: zone)).frame(width: 8, height: 8)
                    Text("Z\(zone)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum ProfileChart {
    static let height: CGFloat = 96
    static let compactHeight: CGFloat = 20
    static let minimumCeiling = 1.25

    /// Effort zones from easy to hard. Height carries the same information, so the
    /// chart does not depend on telling these apart.
    static func color(zone: Int) -> Color {
        switch zone {
        case 1: Color(light: 0x9AA3AE, dark: 0x7D8793)
        case 2: Color(light: 0x2A78D6, dark: 0x3987E5)
        case 3: Color(light: 0x1BAF7A, dark: 0x199E70)
        case 4: Color(light: 0xEDA100, dark: 0xC98500)
        default: Color(light: 0xD9433B, dark: 0xE0554D)
        }
    }
}
