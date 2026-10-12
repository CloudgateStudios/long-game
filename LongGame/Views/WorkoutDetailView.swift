import Analysis
import HealthIngest
import Models
import SwiftData
import SwiftUI

/// Everything stored about one completed workout. Fields the source did not provide
/// are left out rather than shown empty.
struct WorkoutDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let workout: CompletedWorkout
    @Query private var sameSession: [CompletedWorkout]
    @Query private var nearby: [CompletedWorkout]

    /// Other recordings of this same session (for example the watch and a bike computer).
    private var duplicates: [CompletedWorkout] {
        nearby.filter { DuplicateResolver.isSameSession($0.sessionCandidate, workout.sessionCandidate) }
    }

    init(workout: CompletedWorkout) {
        self.workout = workout
        // Other legs of the same multisport workout.
        let sessionID = workout.sessionID
        let externalID = workout.externalID
        _sameSession = Query(
            filter: #Predicate { $0.sessionID != nil && $0.sessionID == sessionID && $0.externalID != externalID },
            sort: \CompletedWorkout.start
        )
        let sportRaw = workout.sportRaw
        let from = workout.start.addingTimeInterval(-86_400)
        let to = workout.start.addingTimeInterval(86_400)
        _nearby = Query(
            filter: #Predicate {
                $0.sportRaw == sportRaw && $0.start >= from && $0.start <= to && $0.externalID != externalID
            },
            sort: \CompletedWorkout.start
        )
    }

    var body: some View {
        List {
            Section {
                header
            }

            Section("Summary") {
                LabeledContent("Duration", value: Format.duration(workout.durationSeconds))
                if let distance = workout.distanceMeters {
                    LabeledContent("Distance", value: Format.distance(distance, sport: distanceSport))
                }
                if let pace = Format.pace(of: workout) {
                    LabeledContent(workout.sport == .bike ? "Average speed" : "Average pace", value: pace)
                }
                if let energy = workout.activeEnergyKcal {
                    LabeledContent(
                        "Active energy", value: "\(energy.formatted(.number.precision(.fractionLength(0)))) kcal")
                }
                if let effort = workout.effortScore {
                    LabeledContent(
                        "Effort", value: "\(effort.formatted(.number.precision(.fractionLength(0...1)))) / 10")
                }
                if let load = workout.load {
                    LabeledContent(
                        "Training load",
                        value: workout.confidence == .estimated ? "\(Format.load(load)) (estimated)" : Format.load(load)
                    )
                }
            }

            if workout.averageHR != nil || workout.maxHR != nil {
                Section("Heart rate") {
                    if let average = workout.averageHR {
                        LabeledContent("Average", value: Format.heartRate(average))
                    }
                    if let max = workout.maxHR {
                        LabeledContent("Maximum", value: Format.heartRate(max))
                    }
                    if let zones = workout.zoneSeconds, zones.contains(where: { $0 > 0 }) {
                        ForEach(Array(zones.enumerated()), id: \.offset) { index, seconds in
                            LabeledContent("Zone \(index + 1)", value: Format.duration(seconds))
                        }
                    }
                }
            }

            if workout.averagePowerWatts != nil || workout.averageCadence != nil {
                Section(workout.sport == .bike ? "Power and cadence" : "Cadence") {
                    if let power = workout.averagePowerWatts {
                        LabeledContent(
                            "Average power", value: "\(power.formatted(.number.precision(.fractionLength(0)))) W")
                    }
                    if let cadence = workout.averageCadence {
                        let unit = workout.sport == .bike ? "rpm" : "spm"
                        LabeledContent(
                            "Average cadence",
                            value: "\(cadence.formatted(.number.precision(.fractionLength(0)))) \(unit)")
                    }
                }
            }

            if let planned = workout.plannedWorkout {
                Section("Planned session") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.title(of: planned))
                        let targets = Format.targets(of: planned)
                        if !targets.isEmpty {
                            Text(targets).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let symbol = planned.status.symbolName {
                        LabeledContent {
                            if let ratio = planned.complianceRatio {
                                Text("\(Format.percent(ratio)) of target")
                            }
                        } label: {
                            Label(planned.status.label, systemImage: symbol)
                                .foregroundStyle(planned.status.color)
                        }
                    }
                }
            }

            if !sameSession.isEmpty {
                Section("Same session") {
                    ForEach(sameSession) { leg in
                        NavigationLink {
                            WorkoutDetailView(workout: leg)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(leg.displayName)
                                    Text(Format.duration(leg.durationSeconds)).font(.subheadline).foregroundStyle(
                                        .secondary)
                                }
                            } icon: {
                                Image(systemName: leg.sport.symbolName)
                            }
                        }
                    }
                }
            }

            if !duplicates.isEmpty {
                Section {
                    ForEach(duplicates) { other in
                        NavigationLink {
                            WorkoutDetailView(workout: other)
                        } label: {
                            LabeledContent(other.sourceName, value: other.isPrimary ? "Counted" : "Not counted")
                        }
                    }
                    if !workout.isPrimary {
                        Button("Count This Recording Instead", action: makePrimary)
                    }
                } header: {
                    Text("Other recordings")
                } footer: {
                    Text(
                        "The same session was recorded more than once. Only one recording counts toward training load and the plan."
                    )
                }
            }

            Section {
                LabeledContent("Source", value: workout.sourceName.isEmpty ? "Unknown" : workout.sourceName)
                LabeledContent(
                    "Recorded as",
                    value: workout.activityName.isEmpty ? workout.sport.displayName : workout.activityName)
                LabeledContent("Heart-rate data", value: workout.confidence == .measured ? "Recorded" : "None")
                if !workout.isPrimary {
                    LabeledContent("Counted", value: "No, duplicate")
                }
            } header: {
                Text("Data")
            } footer: {
                if workout.confidence == .estimated {
                    Text(
                        "This workout has no heart-rate samples, so its training load can only be estimated from its duration."
                    )
                }
            }
        }
        .readableWidth()
        .navigationTitle(workout.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A manual choice sticks: later syncs leave it alone.
    private func makePrimary() {
        for other in duplicates {
            other.isPrimary = false
            other.isPrimaryManuallySet = false
        }
        workout.isPrimary = true
        workout.isPrimaryManuallySet = true
        // The recording that counts is the one the plan should be matched against.
        environment.reconcilePlan()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: workout.sport.symbolName)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.displayName).font(.title3.bold())
                Text(workout.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .foregroundStyle(.secondary)
                Text(timeRange).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var timeRange: String {
        let end = workout.start.addingTimeInterval(workout.durationSeconds)
        return (workout.start..<end).formatted(.interval.hour().minute())
    }

    /// "Other" activities such as hikes read better in road units than pool lengths.
    private var distanceSport: Sport {
        workout.sport == .swim ? .swim : .run
    }
}

extension Format {
    /// Pace for runs, walks and swims; speed for rides. Nil without a distance.
    static func pace(of workout: CompletedWorkout) -> String? {
        guard let meters = workout.distanceMeters, meters > 0, workout.durationSeconds > 0 else { return nil }
        let metric = Locale.current.measurementSystem == .metric
        switch workout.sport {
        case .strength:
            return nil
        case .bike:
            let speed = Measurement(value: meters / workout.durationSeconds, unit: UnitSpeed.metersPerSecond)
                .converted(to: metric ? .kilometersPerHour : .milesPerHour)
            return speed.formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        case .swim:
            let lengths = DistanceEntry.value(meters: meters, sport: .swim) / 100
            return
                "\(minutesAndSeconds(workout.durationSeconds / lengths)) /100 \(DistanceEntry.unit(for: .swim).symbol)"
        case .run, .other:
            let units = DistanceEntry.value(meters: meters, sport: .run)
            return "\(minutesAndSeconds(workout.durationSeconds / units)) /\(DistanceEntry.unit(for: .run).symbol)"
        }
    }

    private static func minutesAndSeconds(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
    }
}
