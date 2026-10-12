import Analysis
import Foundation

/// A structured session with everything a file or device needs alongside the steps.
public struct ExportableWorkout: Sendable, Equatable {
    public var name: String
    public var notes: String
    public var sport: Sport
    public var workout: StructuredWorkout
    public var thresholds: TrainingThresholds
    /// Indoor sessions are sent to a trainer or treadmill; it changes little but labels.
    public var isIndoor: Bool

    public init(
        name: String, notes: String = "", sport: Sport, workout: StructuredWorkout,
        thresholds: TrainingThresholds = .init(), isIndoor: Bool = false
    ) {
        self.name = name
        self.notes = notes
        self.sport = sport
        self.workout = workout.normalized()
        self.thresholds = thresholds
        self.isIndoor = isIndoor
    }
}

public enum WorkoutExportError: Error, Equatable, Sendable {
    /// The format has no way to describe this sport.
    case unsupportedSport
    /// The workout has no steps.
    case empty
    /// Power targets relative to FTP cannot be written without the athlete's FTP.
    case needsFTP
    /// The format describes a workout as power over time, so every step needs a duration.
    case needsTimedSteps
}

/// Files other apps and devices import a structured workout from.
public enum WorkoutFileFormat: String, CaseIterable, Sendable, Identifiable {
    /// Garmin's workout file. Read by Garmin Edge and Forerunner devices and most platforms.
    case fit
    /// Zwift's workout file, also read by several other indoor apps.
    case zwo
    /// Power as a percentage of FTP over time. Read by most trainer software.
    case mrc
    /// As MRC, in watts.
    case erg
    /// Wahoo's plan format, as uploaded through the Wahoo Cloud API.
    case wahooPlan

    public var id: String { rawValue }

    public var fileExtension: String {
        self == .wahooPlan ? "json" : rawValue
    }

    public var displayName: String {
        switch self {
        case .fit: "FIT workout (Garmin and others)"
        case .zwo: "ZWO (Zwift)"
        case .mrc: "MRC (trainer apps, % FTP)"
        case .erg: "ERG (trainer apps, watts)"
        case .wahooPlan: "Wahoo plan (JSON)"
        }
    }

    public func supports(_ sport: Sport) -> Bool {
        switch self {
        case .fit, .wahooPlan: StructuredWorkoutLimits.sports.contains(sport)
        case .zwo, .mrc, .erg: sport == .bike
        }
    }

    public func data(for workout: ExportableWorkout, now: Date = Date()) throws -> Data {
        guard supports(workout.sport) else { throw WorkoutExportError.unsupportedSport }
        guard !workout.workout.isEmpty else { throw WorkoutExportError.empty }
        switch self {
        case .fit: return try FITWorkoutEncoder.data(for: workout, created: now)
        case .zwo: return Data(try ZwiftWorkout.xml(for: workout).utf8)
        case .mrc: return Data(try ErgWorkout.text(for: workout, unit: .percent).utf8)
        case .erg: return Data(try ErgWorkout.text(for: workout, unit: .watts).utf8)
        case .wahooPlan: return try WahooPlan.data(for: workout)
        }
    }

    /// A file name safe on every platform these files travel through.
    public func fileName(for workout: ExportableWorkout) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(workout.name.unicodeScalars.filter(allowed.contains)).trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Workout" : cleaned).\(fileExtension)"
    }
}
