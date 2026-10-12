import Analysis
import Coach
import CoreTransferable
import Models
import SwiftData
import SwiftUI
import WorkoutExport
import WorkoutKit

/// The session as steps a watch or bike computer can run: shows them, asks the coach to
/// build them, and sends them to Apple Watch or out as a file. Changes here apply
/// straight away rather than waiting for Save.
struct StructuredWorkoutSection: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    private var coach: CoachSession { environment.coach }
    let session: PlannedWorkout

    @State private var isBuilding = false
    @State private var failure: CoachError?
    @State private var isIndoor = false
    @State private var watchPlan: WorkoutPlan?
    @State private var isShowingPreview = false
    @State private var watchMessage: String?
    @State private var isScheduling = false

    private var paceUnit: StructuredWorkout.PaceUnit {
        Locale.current.measurementSystem == .metric ? .perKilometer : .perMile
    }

    private var zones: ResolvedZones {
        (try? LoadRecalculator.resolveZones(in: context)) ?? ResolvedZones()
    }

    /// Pace or heart rate for this run: the session's own choice, else the athlete's usual one.
    private var runTargets: RunTargetMode { session.runTargets ?? zones.runTargets }

    /// The steps as they are shown and sent: a run's targets follow `runTargets`.
    private var structure: StructuredWorkout? {
        guard let stored = session.structure else { return nil }
        return session.sport == .run
            ? stored.expressed(as: runTargets, thresholds: zones.thresholds, paceUnit: paceUnit) : stored
    }

    /// Switching between pace and heart rate goes through the threshold pace.
    private var cannotConvert: Bool {
        guard session.sport == .run, let stored = session.structure else { return false }
        return zones.thresholdRunPaceSecondsPerKm == nil && stored.needsConversion(to: runTargets)
    }

    private var exportable: ExportableWorkout? {
        guard let structure else { return nil }
        return ExportableWorkout(
            name: "\(Format.title(of: session)) \(session.date.formatted(.dateTime.day().month(.abbreviated)))",
            notes: session.instructions,
            sport: session.sport,
            workout: structure,
            thresholds: zones.thresholds,
            isIndoor: isIndoor
        )
    }

    var body: some View {
        Section {
            if let structure {
                WorkoutProfileChart(
                    segments: structure.profile(sport: session.sport, thresholds: exportable?.thresholds ?? .init()),
                    paceUnit: paceUnit)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(structure.lines(.init(paceUnit: paceUnit)).enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                    if let seconds = structure.estimatedDurationSeconds {
                        Text("\(Format.duration(seconds)) in total").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if session.sport == .run {
                    Picker(
                        "Targets",
                        selection: Binding(
                            get: { runTargets },
                            set: {
                                session.runTargets = $0
                                environment.saveChanges()
                            })
                    ) {
                        ForEach(RunTargetMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    if cannotConvert {
                        Text(
                            "These steps are written by \(runTargets == .pace ? "heart rate" : "pace"). Add a threshold pace in your profile to switch them."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                Toggle(session.sport == .bike ? "Indoor (trainer)" : "Indoor (treadmill)", isOn: $isIndoor)
                if let exportable {
                    watchButtons(exportable)
                    Menu("Export File", systemImage: "square.and.arrow.up") {
                        ForEach(WorkoutFileFormat.allCases.filter { $0.supports(session.sport) }) { format in
                            if (try? format.data(for: exportable)) != nil {
                                ShareLink(
                                    format.displayName, item: WorkoutFile(workout: exportable, format: format),
                                    preview: SharePreview(format.fileName(for: exportable)))
                            }
                        }
                    }
                }
                Button("Remove Steps", role: .destructive) {
                    session.structure = nil
                    environment.saveChanges()
                }
            } else {
                Text("No steps yet. With steps, this session can run on Apple Watch or a bike computer.")
                    .foregroundStyle(.secondary)
            }
            Button(
                session.structure == nil ? "Build Steps with Coach" : "Rebuild Steps with Coach",
                systemImage: "sparkles"
            ) {
                Task { await build() }
            }
            .disabled(isBuilding || !coach.hasKey)
            if isBuilding { ProgressView("Coach is writing the steps…") }
        } header: {
            Text("Steps")
        } footer: {
            if let failure {
                Text("\(failure.title). \(failure.explanation)").foregroundStyle(.red)
            } else if let watchMessage {
                Text(watchMessage)
            } else if !coach.hasKey {
                Text(
                    "Building steps needs an API key, set in Settings. It is built from the saved targets and instructions."
                )
            } else {
                Text("Built from the saved targets and instructions. Rebuild after changing them.")
            }
        }
    }

    @ViewBuilder
    private func watchButtons(_ exportable: ExportableWorkout) -> some View {
        #if os(iOS)
        Button("Preview for Apple Watch", systemImage: "applewatch") {
            watchPlan = try? WatchWorkout.plan(for: exportable, id: session.uuid)
            isShowingPreview = watchPlan != nil
        }
        .workoutPreview(watchPlan ?? WorkoutPlan(.goal(.init(activity: .running))), isPresented: $isShowingPreview)
        if WorkoutScheduler.isSupported {
            Button(
                "Schedule on Apple Watch for \(session.date.formatted(.dateTime.weekday().day().month(.abbreviated)))",
                systemImage: "calendar.badge.plus"
            ) {
                Task { await schedule(exportable) }
            }
            .disabled(isScheduling)
        }
        #endif
    }

    private func build() async {
        isBuilding = true
        failure = nil
        defer { isBuilding = false }
        do {
            session.structure = try await coach.buildSteps(for: session, in: context)
            environment.saveChanges()
        } catch {
            failure = error
        }
    }

    /// Puts the workout in the Workout app's list on the paired watch for the session's day.
    private func schedule(_ exportable: ExportableWorkout) async {
        guard let plan = try? WatchWorkout.plan(for: exportable, id: session.uuid) else { return }
        var day = Calendar.current.dateComponents([.year, .month, .day], from: session.date)
        day.hour = WatchSchedule.hour
        isScheduling = true
        watchMessage = "Sending to Apple Watch…"
        // The system call can take a long time (in the simulator it never answers), so
        // say so rather than leave the button looking as if nothing happened.
        let patience = Task {
            try? await Task.sleep(for: WatchSchedule.patience)
            if !Task.isCancelled, isScheduling {
                watchMessage = "Still waiting for Apple Watch. Check that it is nearby and unlocked."
            }
        }
        let outcome = await WatchSchedule.schedule(plan, at: day)
        patience.cancel()
        isScheduling = false
        watchMessage =
            switch outcome {
            case .scheduled: "Scheduled. It appears in the Workout app on your Apple Watch."
            case .notAllowed: "Long Game is not allowed to add workouts to your Apple Watch. Allow it in Settings."
            case .failed: "The workout could not be scheduled."
            }
    }
}

private enum WatchSchedule {
    enum Outcome: Sendable {
        case scheduled, notAllowed, failed
    }

    /// Planned sessions have a day but no time; the Workout app wants one.
    static let hour = 7
    /// How long to wait before saying the watch has not answered.
    static let patience: Duration = .seconds(15)

    @concurrent
    nonisolated static func schedule(_ plan: WorkoutPlan, at day: DateComponents) async -> Outcome {
        let scheduler = WorkoutScheduler.shared
        var state = await scheduler.authorizationState
        if state == .notDetermined { state = await scheduler.requestAuthorization() }
        guard state == .authorized else { return .notAllowed }
        // The same session scheduled twice would show twice, so the old copy goes first.
        for scheduled in await scheduler.scheduledWorkouts where scheduled.plan.id == plan.id {
            await scheduler.remove(scheduled.plan, at: scheduled.date)
        }
        await scheduler.schedule(plan, at: day)
        return await scheduler.scheduledWorkouts.contains { $0.plan.id == plan.id } ? .scheduled : .failed
    }
}

/// A workout file written only when it is actually shared.
private struct WorkoutFile: Transferable {
    let workout: ExportableWorkout
    let format: WorkoutFileFormat

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                file.format.fileName(for: file.workout))
            try file.format.data(for: file.workout).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
