import Analysis
import Foundation

/// Writes a FIT workout file: the binary format Garmin devices load structured workouts
/// from, and that most training platforms import. Only the three messages a workout file
/// needs are written (file_id, workout, workout_step), so this is an encoder for that one
/// job and not a general FIT library.
enum FITWorkoutEncoder {
    static func data(for export: ExportableWorkout, created: Date) throws -> Data {
        let steps = Self.steps(for: export)
        let nameSize = min(max(steps.map { $0.name.utf8.count }.max() ?? 0, 1), Limit.stepName) + 1
        let title = text(export.name, size: min(export.name.utf8.count, Limit.workoutName) + 1)

        var records = Data()

        // file_id: says this is a workout file and who wrote it.
        records.append(
            definition(
                local: 0, global: 0,
                fields: [(0, 1, .enum), (1, 2, .uint16), (2, 2, .uint16), (3, 4, .uint32z), (4, 4, .uint32)]))
        records.append(0)
        records.append(FileType.workout)
        records.append(uint16(Manufacturer.development))
        records.append(uint16(0))
        // Serial number and creation time together identify the file to a device.
        let timestamp = UInt32(max(created.timeIntervalSince1970 - fitEpoch, 0))
        records.append(uint32(timestamp == 0 ? 1 : timestamp))
        records.append(uint32(timestamp))

        // workout: sport, name and how many steps follow.
        records.append(
            definition(
                local: 1, global: 26,
                fields: [(4, 1, .enum), (5, 4, .uint32z), (6, 2, .uint16), (8, UInt8(title.count), .string)]))
        records.append(1)
        records.append(export.sport == .run ? SportCode.running : SportCode.cycling)
        records.append(uint32(Capability.tcx))
        records.append(uint16(UInt16(steps.count)))
        records.append(title)

        // workout_step, one per step. Names are padded to a common size so one definition serves all.
        records.append(
            definition(
                local: 2, global: 27,
                fields: [
                    (254, 2, .uint16), (0, UInt8(nameSize), .string), (1, 1, .enum), (2, 4, .uint32), (3, 1, .enum),
                    (4, 4, .uint32),
                    (5, 4, .uint32), (6, 4, .uint32), (7, 1, .enum),
                ]))
        for (index, step) in steps.enumerated() {
            records.append(2)
            records.append(uint16(UInt16(index)))
            records.append(text(step.name, size: nameSize))
            records.append(step.durationType)
            records.append(uint32(step.durationValue))
            records.append(step.targetType)
            records.append(uint32(step.targetValue))
            records.append(uint32(step.customLow))
            records.append(uint32(step.customHigh))
            records.append(step.intensity)
        }

        var file = Data([14, protocolVersion])
        file.append(uint16(profileVersion))
        file.append(uint32(UInt32(records.count)))
        file.append(Data(".FIT".utf8))
        file.append(uint16(crc(file)))
        file.append(records)
        file.append(uint16(crc(file)))
        return file
    }

    // MARK: Steps

    struct Step: Equatable {
        var name = ""
        var durationType: UInt8 = Duration.open
        var durationValue: UInt32 = invalid
        var targetType: UInt8 = Target.open
        var targetValue: UInt32 = 0
        var customLow: UInt32 = invalid
        var customHigh: UInt32 = invalid
        var intensity: UInt8 = 0xFF
    }

    /// The flat list a FIT file holds: a repeat is its steps followed by a step that
    /// sends the device back to the first of them.
    static func steps(for export: ExportableWorkout) -> [Step] {
        var result: [Step] = []
        for block in export.workout.blocks {
            let first = result.count
            result += block.steps.map { step($0, export) }
            if block.repeats > 1 {
                result.append(
                    Step(
                        durationType: Duration.repeatUntilStepsComplete, durationValue: UInt32(first),
                        targetValue: UInt32(block.repeats)))
            }
        }
        return result
    }

    private static func step(_ source: StructuredWorkout.Step, _ export: ExportableWorkout) -> Step {
        var step = Step(name: source.note ?? source.kind.displayName)
        switch source.kind {
        case .warmup: step.intensity = Intensity.warmup
        case .work: step.intensity = Intensity.active
        case .recovery: step.intensity = Intensity.recovery
        case .cooldown: step.intensity = Intensity.cooldown
        }
        if let seconds = source.durationSeconds {
            step.durationType = Duration.time
            step.durationValue = UInt32((seconds * 1000).rounded())
        } else if let meters = source.distanceMeters {
            step.durationType = Duration.distance
            step.durationValue = UInt32((meters * 100).rounded())
        }

        guard let target = source.target else { return step }
        func custom(_ type: UInt8, _ range: ClosedRange<Double>, scale: Double = 1, offset: Double = 0) {
            step.targetType = type
            step.customLow = UInt32((range.lowerBound * scale + offset).rounded())
            step.customHigh = UInt32((range.upperBound * scale + offset).rounded())
        }
        switch target.kind {
        case .ftpPercent:
            // Values up to 1000 are read as a percentage of the FTP set on the device.
            custom(Target.power, target.low...target.high)
        case .power:
            custom(Target.power, target.low...target.high, offset: Offset.watts)
        case .heartRate, .hrZone:
            if let bpm = target.beatsPerMinute(export.thresholds) {
                custom(Target.heartRate, bpm, offset: Offset.beatsPerMinute)
            } else if target.kind == .hrZone {
                // Without the athlete's zones, name the zone and let the device use its own.
                step.targetType = Target.heartRate
                step.targetValue = UInt32(target.low)
            }
        case .pace:
            if let speed = target.metersPerSecond { custom(Target.speed, speed, scale: 1000) }
        case .rpe:
            break
        }
        return step
    }

    // MARK: FIT profile values

    static let protocolVersion: UInt8 = 0x20
    static let profileVersion: UInt16 = 21141
    static let invalid: UInt32 = 0xFFFF_FFFF
    /// FIT counts seconds from 31 December 1989 UTC.
    static let fitEpoch: TimeInterval = 631_065_600

    enum FileType { static let workout: UInt8 = 5 }
    enum Manufacturer { static let development: UInt16 = 255 }
    enum SportCode {
        static let running: UInt8 = 1
        static let cycling: UInt8 = 2
    }
    enum Capability { static let tcx: UInt32 = 0x20 }
    enum Duration {
        static let time: UInt8 = 0
        static let distance: UInt8 = 1
        static let open: UInt8 = 5
        static let repeatUntilStepsComplete: UInt8 = 6
    }
    enum Target {
        static let speed: UInt8 = 0
        static let heartRate: UInt8 = 1
        static let open: UInt8 = 2
        static let power: UInt8 = 4
    }
    enum Intensity {
        static let active: UInt8 = 0
        static let warmup: UInt8 = 2
        static let cooldown: UInt8 = 3
        static let recovery: UInt8 = 4
    }
    /// Custom targets above these offsets are absolute; below them they are percentages.
    enum Offset {
        static let watts = 1000.0
        static let beatsPerMinute = 100.0
    }
    enum Limit {
        static let workoutName = 40
        static let stepName = 24
    }

    // MARK: Encoding

    enum BaseType: UInt8 {
        case `enum` = 0x00
        case string = 0x07
        case uint16 = 0x84
        case uint32 = 0x86
        case uint32z = 0x8C
    }

    private static func definition(local: UInt8, global: UInt16, fields: [(number: UInt8, size: UInt8, type: BaseType)])
        -> Data
    {
        // Header bit 6 marks a definition; then reserved, little-endian, message number, field count.
        var data = Data([0x40 | local, 0, 0])
        data.append(uint16(global))
        data.append(UInt8(fields.count))
        for field in fields {
            data.append(contentsOf: [field.number, field.size, field.type.rawValue])
        }
        return data
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    /// UTF-8, cut at a character boundary to fit, null-terminated and padded to `size`.
    private static func text(_ string: String, size: Int) -> Data {
        var bytes: [UInt8] = []
        for character in string {
            let next = Array(String(character).utf8)
            if bytes.count + next.count > size - 1 { break }
            bytes += next
        }
        return Data(bytes + [UInt8](repeating: 0, count: size - bytes.count))
    }

    static func crc(_ data: Data) -> UInt16 {
        let table: [UInt16] = [
            0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, 0xA001, 0x6C00, 0x7800, 0xB401, 0x5000,
            0x9C01, 0x8801, 0x4400,
        ]
        var crc: UInt16 = 0
        for byte in data {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
