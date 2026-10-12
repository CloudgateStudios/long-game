import Analysis
import Foundation
import Models
import SwiftUI

enum Format {
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// Distance in the unit the sport is planned in (pool lengths for swimming).
    static func distance(_ meters: Double, sport: Sport) -> String {
        let unit = DistanceEntry.unit(for: sport)
        return Measurement(value: DistanceEntry.value(meters: meters, sport: sport), unit: unit)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func heartRate(_ bpm: Double) -> String {
        "\(bpm.formatted(.number.precision(.fractionLength(0)))) bpm"
    }

    static func targets(of workout: PlannedWorkout) -> String {
        // A rest or flex day has no targets; its note is all there is to say about it.
        if workout.isDayMarker { return workout.instructions }
        var parts: [String] = []
        if let seconds = workout.targetDurationSeconds { parts.append(duration(seconds)) }
        if let meters = workout.targetDistanceMeters { parts.append(distance(meters, sport: workout.sport)) }
        if !workout.targetIntensity.isEmpty { parts.append(workout.targetIntensity) }
        return parts.joined(separator: " · ")
    }

    static func title(of workout: PlannedWorkout) -> String {
        switch workout.sessionType {
        case .rest: "Rest day"
        case .flex: "Flex day"
        case .strength where workout.sport == .strength: "Strength"
        default: "\(workout.sessionType.displayName) \(workout.sport.displayName.lowercased())"
        }
    }
}

extension SessionType {
    /// Symbol for a rest or flex day, which has no sport to show.
    var dayMarkerSymbolName: String? {
        switch self {
        case .rest: "moon.zzz"
        case .flex: "shuffle"
        default: nil
        }
    }
}

extension PlannedWorkout {
    var symbolName: String { sessionType.dayMarkerSymbolName ?? sport.symbolName }
}

/// Distances are stored in meters and typed in the unit that suits the sport and locale.
enum DistanceEntry {
    static func unit(for sport: Sport, locale: Locale = .current) -> UnitLength {
        let metric = locale.measurementSystem == .metric
        if sport == .swim { return metric ? .meters : .yards }
        return metric ? .kilometers : .miles
    }

    static func value(meters: Double, sport: Sport) -> Double {
        Measurement(value: meters, unit: UnitLength.meters).converted(to: unit(for: sport)).value
    }

    static func meters(value: Double, sport: Sport) -> Double {
        Measurement(value: value, unit: unit(for: sport)).converted(to: .meters).value
    }
}

extension ShapeStyle where Self == Color {
    /// Page background behind cards, matching grouped lists on each platform.
    static var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

extension PlannedStatus {
    /// Nil while a session is still ahead: only outcomes get a badge.
    var symbolName: String? {
        switch self {
        case .planned: nil
        case .done: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .overdone: "arrow.up.circle.fill"
        case .missed, .skipped: "xmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .planned: "Planned"
        case .done: "Done"
        case .partial: "Partly done"
        case .overdone: "Overdone"
        case .missed: "Missed"
        case .skipped: "Skipped"
        }
    }

    var color: Color {
        switch self {
        case .planned: .secondary
        case .done: .green
        case .partial: .orange
        case .overdone: .purple
        case .missed, .skipped: .red
        }
    }
}

extension Format {
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

extension Color {
    /// A color with separate light and dark values, given as 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        let (lightRGB, darkRGB) = (components(light), components(dark))
        #if os(iOS)
        self.init(
            uiColor: UIColor { traits in
                let (r, g, b) = traits.userInterfaceStyle == .dark ? darkRGB : lightRGB
                return UIColor(red: r, green: g, blue: b, alpha: 1)
            })
        #else
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkRGB : lightRGB
                return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            })
        #endif
    }

    // Chart series colors. A fixed order checked for colour-blind separation in both
    // appearances; keep the order and do not reuse these for status.
    static let series1 = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let series2 = Color(light: 0xEB6834, dark: 0xD95926)
    static let series3 = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let series4 = Color(light: 0xEDA100, dark: 0xC98500)
    static let series5 = Color(light: 0xE87BA4, dark: 0xD55181)
}

extension Sport {
    /// The sport's color in charts. It follows the sport, never its rank.
    var chartColor: Color {
        switch self {
        case .swim: .series1
        case .bike: .series2
        case .run: .series3
        case .strength: .series4
        case .other: .series5
        }
    }
}

extension Format {
    static func load(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    static func ratio(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

extension View {
    /// Keeps lists and forms to a comfortable reading width on iPad and Mac, centered on
    /// the page background, instead of stretching rows across the whole window.
    func readableWidth(_ width: CGFloat = 760) -> some View {
        frame(maxWidth: width)
            .frame(maxWidth: .infinity)
            .background(.pageBackground)
    }
}

/// Paces are stored in seconds per kilometre and typed as minutes:seconds in the locale's unit.
enum PaceEntry {
    private static var metersPerUnit: Double {
        Locale.current.measurementSystem == .metric ? 1000 : 1609.344
    }

    static var unitLabel: String {
        Locale.current.measurementSystem == .metric ? "/km" : "/mi"
    }

    static func text(secondsPerKm: Double) -> String {
        let total = Int((secondsPerKm * metersPerUnit / 1000).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Nil unless the text is a plausible pace such as "4:30" or "7:15".
    static func secondsPerKm(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Int(parts[0]), parts[1].count == 2, let seconds = Int(parts[1]),
            (2...20).contains(minutes), (0..<60).contains(seconds)
        else { return nil }
        return Double(minutes * 60 + seconds) * 1000 / metersPerUnit
    }
}
