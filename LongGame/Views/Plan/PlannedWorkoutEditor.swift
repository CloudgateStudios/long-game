import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

/// Creates a session (when `workout` is nil) or edits an existing one.
struct PlannedWorkoutEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let plan: TrainingPlan
    let workout: PlannedWorkout?
    private let initialDistance: Double?

    @State private var date: Date
    @State private var sport: Sport
    @State private var sessionType: SessionType
    @State private var minutes: Int?
    @State private var distance: Double?
    @State private var intensity: String
    @State private var instructions: String

    init(plan: TrainingPlan, workout: PlannedWorkout?, date: Date) {
        self.plan = plan
        self.workout = workout
        let sport = workout?.sport ?? .run
        _date = State(initialValue: date)
        _sport = State(initialValue: sport)
        _sessionType = State(initialValue: workout?.sessionType ?? .easy)
        _minutes = State(initialValue: workout?.targetDurationSeconds.map { Int(($0 / 60).rounded()) })
        initialDistance = workout?.targetDistanceMeters.map {
            (DistanceEntry.value(meters: $0, sport: sport) * 100).rounded() / 100
        }
        _distance = State(initialValue: initialDistance)
        _intensity = State(initialValue: workout?.targetIntensity ?? "")
        _instructions = State(initialValue: workout?.instructions ?? "")
    }

    private var isDayMarker: Bool { sessionType.isDayMarker }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Type", selection: $sessionType) {
                        ForEach(SessionType.allCases) { Text($0.displayName).tag($0) }
                    }
                    if !isDayMarker {
                        Picker("Sport", selection: $sport) {
                            ForEach(Sport.allCases) { Label($0.displayName, systemImage: $0.symbolName).tag($0) }
                        }
                    }
                } footer: {
                    switch sessionType {
                    case .rest: Text("A day fully off. Nothing is matched to it and it never counts as missed.")
                    case .flex:
                        Text(
                            "A day you decide on when it comes: train, rest, or anything between. Whatever you do is logged as usual, and the day never counts as missed."
                        )
                    default: EmptyView()
                    }
                }

                if !isDayMarker {
                    Section("Targets") {
                        LabeledContent("Duration") {
                            HStack {
                                TextField("Optional", value: $minutes, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    #if os(iOS)
                                .keyboardType(.numberPad)
                                    #endif
                                Text("min").foregroundStyle(.secondary)
                            }
                        }
                        if sport != .strength {
                            LabeledContent("Distance") {
                                HStack {
                                    TextField("Optional", value: $distance, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        #if os(iOS)
                                    .keyboardType(.decimalPad)
                                        #endif
                                    Text(DistanceEntry.unit(for: sport).symbol).foregroundStyle(.secondary)
                                }
                            }
                        }
                        LabeledContent("Intensity") {
                            TextField("Zone or description", text: $intensity)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section(isDayMarker ? "Notes" : sport == .strength ? "Exercises and sets" : "Instructions") {
                    TextField(
                        isDayMarker ? "Notes for this day" : "Notes for this session", text: $instructions,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                }

                if let workout {
                    Section {
                        Button("Delete Session", role: .destructive) {
                            context.delete(workout)
                            environment.reconcilePlan()
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(workout == nil ? "New Session" : "Edit Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onChange(of: sport) { old, new in
                // Keep the typed number meaning the same distance when the unit changes.
                if let distance, DistanceEntry.unit(for: old) != DistanceEntry.unit(for: new) {
                    let meters = DistanceEntry.meters(value: distance, sport: old)
                    self.distance = (DistanceEntry.value(meters: meters, sport: new) * 100).rounded() / 100
                }
                if new == .strength { sessionType = .strength }
            }
            .onChange(of: sessionType) { _, new in
                if new == .strength { sport = .strength }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func save() {
        // Untouched distances keep their exact stored value rather than a rounded round trip.
        let distanceChanged = distance != initialDistance || sport != workout?.sport
        let target: PlannedWorkout
        if let workout {
            target = workout
        } else {
            target = PlannedWorkout(date: date, sport: sport, sessionType: sessionType)
            context.insert(target)
            target.plan = plan
        }
        target.date = Calendar.current.startOfDay(for: date)
        target.sessionType = sessionType
        target.sport = sport
        target.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDayMarker {
            target.targetDurationSeconds = nil
            target.targetDistanceMeters = nil
            target.targetIntensity = ""
        } else {
            target.targetDurationSeconds = minutes.flatMap { $0 > 0 ? Double($0) * 60 : nil }
            if sport == .strength {
                target.targetDistanceMeters = nil
            } else if distanceChanged {
                target.targetDistanceMeters = distance.flatMap {
                    $0 > 0 ? DistanceEntry.meters(value: $0, sport: sport) : nil
                }
            }
            target.targetIntensity = intensity.trimmingCharacters(in: .whitespaces)
        }
        // Re-matches, saves, and so starts the upload to iCloud.
        environment.reconcilePlan()
        dismiss()
    }
}

/// Shows what a session was matched to and lets the user override it.
struct MatchSection: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    let session: PlannedWorkout

    var body: some View {
        Section {
            if session.matchedWorkout != nil {
                NavigationLink("Choose a Different Workout") { MatchPicker(session: session) }
                Button("Remove Match") {
                    PlanReconciler.unmatch(session)
                    environment.reconcilePlan()
                }
            } else {
                Text(
                    session.status == .missed
                        ? "No workout matched. This session counts as missed." : "No workout matched yet."
                )
                .foregroundStyle(.secondary)
                NavigationLink("Choose a Workout") { MatchPicker(session: session) }
            }
            if session.isManualMatch {
                Button("Match Automatically") {
                    try? PlanReconciler.resetToAutomatic(session, in: context)
                    environment.reconcilePlan()
                }
            }
        } header: {
            Text("Match")
        } footer: {
            if session.isManualMatch {
                Text("You set this by hand, so automatic matching leaves it alone.")
            }
        }
    }
}

/// Completed workouts near the session's date that it could be matched to.
private struct MatchPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Query private var candidates: [CompletedWorkout]
    let session: PlannedWorkout

    init(session: PlannedWorkout) {
        self.session = session
        let from = session.date.addingTimeInterval(-7 * 86_400)
        let to = session.date.addingTimeInterval(8 * 86_400)
        _candidates = Query(
            filter: #Predicate { $0.isPrimary && $0.start >= from && $0.start <= to },
            sort: \CompletedWorkout.start,
            order: .reverse
        )
    }

    var body: some View {
        List(candidates) { workout in
            Button {
                PlanReconciler.match(session, to: workout)
                environment.reconcilePlan()
                dismiss()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.displayName).foregroundStyle(.primary)
                        Text(
                            "\(workout.start.formatted(.dateTime.weekday().day().month().hour().minute())) · \(Format.duration(workout.durationSeconds))"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        if let other = workout.plannedWorkout, other !== session {
                            Text("Matched to \(Format.title(of: other))").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: workout.sport.symbolName).foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "No workouts nearby", systemImage: "figure.run",
                    description: Text("There are no completed workouts within a week of this session."))
            }
        }
        .navigationTitle("Choose Workout")
    }
}
