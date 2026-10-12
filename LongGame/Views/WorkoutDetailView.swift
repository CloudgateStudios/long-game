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

            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    StatTile(title: "Time", value: Format.duration(workout.durationSeconds))
                    if let distance = workout.distanceMeters {
                        StatTile(title: "Distance", value: Format.distance(distance, sport: distanceSport))
                    }
                    if let pace = Format.pace(of: workout) {
                        StatTile(title: workout.sport == .bike ? "Speed" : "Pace", value: pace)
                    }
                    if let load = workout.load {
                        StatTile(
                            title: "Training load", value: Format.load(load),
                            caption: workout.confidence == .estimated ? "estimated" : nil)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker("Perceived effort", selection: feedback(\.perceivedEffort)) {
                    Text("Not rated").tag(Int?.none)
                    ForEach(1...10, id: \.self) { Text("\($0) of 10").tag(Int?.some($0)) }
                }
                Picker("Felt", selection: feedback(\.feel)) {
                    Text("Not rated").tag(WorkoutFeel?.none)
                    ForEach(WorkoutFeel.allCases) { Text($0.displayName).tag(WorkoutFeel?.some($0)) }
                }
                TextField("Notes", text: feedback(\.athleteNotes), axis: .vertical)
                    .lineLimit(1...6)
            } header: {
                Text("How it went")
            } footer: {
                Text("Your own rating, where 10 is all out. The coach reads this alongside the numbers.")
            }

            if let planned = workout.plannedWorkout {
                Section("Planned session") {
                    NavigationLink {
                        PlannedWorkoutDetailView(workout: planned)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Format.title(of: planned))
                                let targets = Format.targets(of: planned)
                                if !targets.isEmpty {
                                    Text(targets).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            StatusChip(workout: planned)
                        }
                    }
                }
            }

            if workout.averageHR != nil || workout.maxHR != nil {
                Section("Heart rate") {
                    HStack(alignment: .top) {
                        if let average = workout.averageHR {
                            StatTile(title: "Average", value: Format.heartRate(average))
                        }
                        if let max = workout.maxHR {
                            StatTile(title: "Maximum", value: Format.heartRate(max))
                        }
                    }
                    .padding(.vertical, 4)
                    if let zones = workout.zoneSeconds, zones.contains(where: { $0 > 0 }) {
                        ZoneBar(seconds: zones)
                    }
                }
            }

            if workout.activeEnergyKcal != nil || workout.effortScore != nil || workout.averagePowerWatts != nil
                || workout.averageCadence != nil
            {
                Section("More") {
                    if let energy = workout.activeEnergyKcal {
                        LabeledContent(
                            "Active energy", value: "\(energy.formatted(.number.precision(.fractionLength(0)))) kcal")
                    }
                    if let effort = workout.effortScore {
                        LabeledContent(
                            "Effort", value: "\(effort.formatted(.number.precision(.fractionLength(0...1)))) / 10")
                    }
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
        // Notes are saved once on the way out rather than on every keystroke.
        .onDisappear { environment.saveChanges() }
    }

    private func feedback<Value>(_ field: ReferenceWritableKeyPath<CompletedWorkout, Value>) -> Binding<Value> {
        Binding(
            get: { workout[keyPath: field] },
            set: { workout[keyPath: field] = $0 }
        )
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
                .foregroundStyle(workout.sport.chartColor)
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
