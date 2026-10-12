import Analysis
import Foundation
import Testing
@testable import WorkoutExport

enum Sample {
    typealias Step = StructuredWorkout.Step
    typealias Target = StructuredWorkout.Target

    static let athlete = TrainingThresholds(ftpWatts: 250, hrZoneUpperBounds: [120, 140, 155, 170], maxHR: 185)

    static let ride = ExportableWorkout(
        name: "VO2 5 × 4 min",
        notes: "Hard but repeatable. Stop if power drops more than 10%.",
        sport: .bike,
        workout: StructuredWorkout(blocks: [
            .init(steps: [Step(.warmup, seconds: 600, target: Target(.ftpPercent, 50, 65))]),
            .init(repeats: 5, steps: [Step(.work, seconds: 240, target: Target(.ftpPercent, 105, 110)), Step(.recovery, seconds: 180, target: Target(.ftpPercent, 50))]),
            .init(steps: [Step(.work, seconds: 300, target: Target(.hrZone, 2))]),
            .init(steps: [Step(.cooldown, seconds: 600, target: Target(.ftpPercent, 40, 55))]),
        ]),
        thresholds: athlete,
        isIndoor: true
    )

    static let run = ExportableWorkout(
        name: "6 × 800 m",
        sport: .run,
        workout: StructuredWorkout(blocks: [
            .init(steps: [Step(.warmup, seconds: 900, target: Target(.hrZone, 2))]),
            .init(repeats: 6, steps: [Step(.work, meters: 800, target: Target(.pace, 240, 250), note: "5K effort"), Step(.recovery, seconds: 90)]),
            .init(steps: [Step(.cooldown)]),
        ]),
        thresholds: athlete
    )
}

@Suite struct TextFormatTests {
    @Test func zwiftUsesItsOwnIntervalAndRampElements() throws {
        let xml = try String(decoding: WorkoutFileFormat.zwo.data(for: Sample.ride), as: UTF8.self)
        #expect(xml.contains("<name>VO2 5 × 4 min</name>"))
        #expect(xml.contains("<Warmup Duration=\"600\" PowerLow=\"0.50\" PowerHigh=\"0.65\"/>"))
        #expect(xml.contains("<IntervalsT Repeat=\"5\" OnDuration=\"240\" OffDuration=\"180\" OnPower=\"1.08\" OffPower=\"0.50\"/>"))
        // A heart-rate zone becomes the middle of the matching power zone.
        #expect(xml.contains("<SteadyState Duration=\"300\" Power=\"0.66\"/>"))
        #expect(xml.contains("<Cooldown Duration=\"600\" PowerLow=\"0.55\" PowerHigh=\"0.40\"/>"))
        // Well-formed XML.
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse())
    }

    @Test func zwiftEscapesNames() throws {
        var ride = Sample.ride
        ride.name = "Over & <under>"
        let xml = try String(decoding: WorkoutFileFormat.zwo.data(for: ride), as: UTF8.self)
        #expect(xml.contains("<name>Over &amp; &lt;under&gt;</name>"))
        #expect(XMLParser(data: Data(xml.utf8)).parse())
    }

    @Test func mrcAndErgAreSquareEdgedPowerOverTime() throws {
        let mrc = try String(decoding: WorkoutFileFormat.mrc.data(for: Sample.ride), as: UTF8.self)
        #expect(mrc.contains("MINUTES PERCENT"))
        let lines = mrc.components(separatedBy: "\n")
        let data = Array(lines[(lines.firstIndex(of: "[COURSE DATA]")! + 1)..<lines.firstIndex(of: "[END COURSE DATA]")!])
        // 1 warm-up, 10 interval steps, 1 steady, 1 cool-down, two points each.
        #expect(data.count == 26)
        #expect(Array(data.prefix(4)) == ["0.00\t58", "10.00\t58", "10.00\t108", "14.00\t108"])
        #expect(data.last == "60.00\t48")

        let erg = try String(decoding: WorkoutFileFormat.erg.data(for: Sample.ride), as: UTF8.self)
        #expect(erg.contains("FTP = 250"))
        #expect(erg.contains("MINUTES WATTS"))
        #expect(erg.contains("10.00\t269\n14.00\t269"))
    }

    @Test func powerFormatsRefuseWhatTheyCannotSay() {
        #expect(throws: WorkoutExportError.unsupportedSport) { try WorkoutFileFormat.zwo.data(for: Sample.run) }
        var ride = Sample.ride
        ride.thresholds = TrainingThresholds()
        #expect(throws: WorkoutExportError.needsFTP) { try WorkoutFileFormat.erg.data(for: ride) }
        // Percentages need no FTP.
        #expect(throws: Never.self) { try WorkoutFileFormat.mrc.data(for: ride) }
        ride.workout.blocks.append(.init(steps: [.init(.work, meters: 1000)]))
        #expect(throws: WorkoutExportError.needsTimedSteps) { try WorkoutFileFormat.mrc.data(for: ride) }
        ride.workout = StructuredWorkout(blocks: [])
        #expect(throws: WorkoutExportError.empty) { try WorkoutFileFormat.fit.data(for: ride) }
    }

    @Test func fileNamesAreSafe() {
        #expect(WorkoutFileFormat.zwo.fileName(for: Sample.ride) == "VO2 5  4 min.zwo")
        #expect(WorkoutFileFormat.wahooPlan.fileName(for: Sample.run) == "6  800 m.json")
    }
}

@Suite struct WahooPlanTests {
    @Test func aRideFollowsThePublishedFormat() throws {
        let object = try JSONSerialization.jsonObject(with: WorkoutFileFormat.wahooPlan.data(for: Sample.ride)) as! [String: Any]
        let header = object["header"] as! [String: Any]
        #expect(header["version"] as? String == "1.0.0")
        #expect(header["workout_type_family"] as? Int == 0)
        #expect(header["workout_type_location"] as? Int == 0)
        #expect(header["ftp"] as? Int == 250)
        #expect(header["duration_s"] as? Int == 3600)

        let intervals = object["intervals"] as! [[String: Any]]
        #expect(intervals.count == 4)
        #expect(intervals[0]["intensity_type"] as? String == "wu")
        #expect(intervals[0]["exit_trigger_type"] as? String == "time")
        #expect(intervals[0]["exit_trigger_value"] as? Int == 600)
        // Four more times after the first makes five.
        #expect(intervals[1]["exit_trigger_type"] as? String == "repeat")
        #expect(intervals[1]["exit_trigger_value"] as? Int == 4)
        let inner = intervals[1]["intervals"] as! [[String: Any]]
        let target = (inner[0]["targets"] as! [[String: Any]])[0]
        #expect(target["type"] as? String == "ftp")
        #expect(target["low"] as? Double == 1.05)
        #expect(target["high"] as? Double == 1.1)
        let heartRate = (intervals[2]["targets"] as! [[String: Any]])[0]
        #expect(heartRate["type"] as? String == "hr")
        #expect(heartRate["low"] as? Double == 120)
    }

    @Test func aRunUsesDistanceAndSpeed() throws {
        var run = Sample.run
        // The format has no lap-button step.
        #expect(throws: WorkoutExportError.needsTimedSteps) { try WorkoutFileFormat.wahooPlan.data(for: run) }
        run.workout.blocks.removeLast()
        let object = try JSONSerialization.jsonObject(with: WorkoutFileFormat.wahooPlan.data(for: run)) as! [String: Any]
        #expect((object["header"] as! [String: Any])["workout_type_family"] as? Int == 1)
        let rep = ((object["intervals"] as! [[String: Any]])[1]["intervals"] as! [[String: Any]])[0]
        #expect(rep["exit_trigger_type"] as? String == "distance")
        #expect(rep["exit_trigger_value"] as? Int == 800)
        #expect(rep["name"] as? String == "5K effort")
        let speed = (rep["targets"] as! [[String: Any]])[0]
        #expect(speed["type"] as? String == "speed")
        #expect(speed["low"] as? Double == 4.0)
        #expect(speed["high"] as? Double == 4.17)
    }
}

@Suite struct FITWorkoutTests {
    let created = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theFileIsWellFormed() throws {
        let data = try WorkoutFileFormat.fit.data(for: Sample.ride, now: created)
        let bytes = [UInt8](data)
        #expect(bytes[0] == 14)
        #expect(String(decoding: bytes[8..<12], as: UTF8.self) == ".FIT")
        let size = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        #expect(size == bytes.count - 14 - 2)
        // A CRC run over data that ends with its own CRC comes out as zero.
        #expect(FITWorkoutEncoder.crc(data.prefix(14)) == 0)
        #expect(FITWorkoutEncoder.crc(data) == 0)
    }

    @Test func aRideReadsBackStepByStep() throws {
        let messages = try FITReader.read(WorkoutFileFormat.fit.data(for: Sample.ride, now: created))
        let fileID = try #require(messages.first { $0.global == 0 })
        #expect(fileID.number(0) == 5)
        #expect(fileID.number(4) == UInt32(1_790_000_000 - 631_065_600))

        let workout = try #require(messages.first { $0.global == 26 })
        #expect(workout.number(4) == 2)
        #expect(workout.number(6) == 6)
        #expect(workout.string(8) == "VO2 5 × 4 min")

        let steps = messages.filter { $0.global == 27 }
        #expect(steps.map { $0.number(254) } == [0, 1, 2, 3, 4, 5])
        // Warm-up: 10 minutes in milliseconds at 50–65% of FTP.
        #expect(steps[0].string(0) == "Warm up")
        #expect([steps[0].number(1), steps[0].number(2), steps[0].number(3), steps[0].number(5), steps[0].number(6), steps[0].number(7)] == [0, 600_000, 4, 50, 65, 2])
        #expect([steps[1].number(2), steps[1].number(5), steps[1].number(6), steps[1].number(7)] == [240_000, 105, 110, 0])
        #expect([steps[2].number(2), steps[2].number(5), steps[2].number(7)] == [180_000, 50, 4])
        // The repeat goes back to step 1 until it has been done five times.
        #expect([steps[3].number(1), steps[3].number(2), steps[3].number(4)] == [6, 1, 5])
        // Zone 2 as the athlete's own beats per minute, offset by 100.
        #expect([steps[4].number(3), steps[4].number(5), steps[4].number(6)] == [1, 220, 240])
        #expect(steps[5].number(7) == 3)
    }

    @Test func aRunUsesDistanceSpeedAndOpenSteps() throws {
        var run = Sample.run
        run.thresholds = TrainingThresholds()
        let messages = try FITReader.read(WorkoutFileFormat.fit.data(for: run, now: created))
        #expect(messages.first { $0.global == 26 }?.number(4) == 1)
        let steps = messages.filter { $0.global == 27 }
        #expect(steps.count == 5)
        // With no zones known, the device's own zone 2.
        #expect([steps[0].number(3), steps[0].number(4)] == [1, 2])
        // 800 m in centimetres at 4.0–4.167 m/s in millimetres per second.
        #expect(steps[1].string(0) == "5K effort")
        #expect([steps[1].number(1), steps[1].number(2), steps[1].number(3), steps[1].number(5), steps[1].number(6)] == [1, 80_000, 0, 4000, 4167])
        #expect([steps[2].number(1), steps[2].number(2), steps[2].number(3)] == [0, 90_000, 2])
        #expect([steps[3].number(1), steps[3].number(2), steps[3].number(4)] == [6, 1, 6])
        #expect([steps[4].number(1), steps[4].number(3)] == [5, 2])
    }

    @Test func absoluteWattsAreOffset() throws {
        var ride = Sample.ride
        ride.workout = StructuredWorkout(blocks: [.init(steps: [.init(.work, seconds: 1200, target: .init(.power, 220, 240))])])
        let step = try #require(try FITReader.read(WorkoutFileFormat.fit.data(for: ride, now: created)).first { $0.global == 27 })
        #expect([step.number(3), step.number(5), step.number(6)] == [4, 1220, 1240])
    }
}

/// Just enough of a FIT decoder to read back what the encoder wrote, driven by the
/// definition messages in the file rather than by knowledge of the encoder.
enum FITReader {
    struct Message {
        var global: UInt16
        var fields: [UInt8: [UInt8]]

        func number(_ field: UInt8) -> UInt32? {
            fields[field].map { $0.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        }

        func string(_ field: UInt8) -> String? {
            fields[field].map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    struct Malformed: Error {}

    static func read(_ data: Data) throws -> [Message] {
        let bytes = [UInt8](data)
        var index = Int(bytes[0])
        let end = bytes.count - 2
        var definitions: [UInt8: (global: UInt16, fields: [(UInt8, Int)])] = [:]
        var messages: [Message] = []
        while index < end {
            let header = bytes[index]
            index += 1
            let local = header & 0x0F
            if header & 0x40 != 0 {
                guard bytes[index + 1] == 0 else { throw Malformed() }
                let global = UInt16(bytes[index + 2]) | UInt16(bytes[index + 3]) << 8
                let count = Int(bytes[index + 4])
                index += 5
                var fields: [(UInt8, Int)] = []
                for _ in 0..<count {
                    fields.append((bytes[index], Int(bytes[index + 1])))
                    index += 3
                }
                definitions[local] = (global, fields)
            } else {
                guard let definition = definitions[local] else { throw Malformed() }
                var message = Message(global: definition.global, fields: [:])
                for (number, size) in definition.fields {
                    message.fields[number] = Array(bytes[index..<index + size])
                    index += size
                }
                messages.append(message)
            }
        }
        guard index == end else { throw Malformed() }
        return messages
    }
}

/// Writes every sample in every format when asked, for checking against other tools:
/// `LONGGAME_EXPORT_DIR=/some/dir swift test --filter SampleFiles`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LONGGAME_EXPORT_DIR"] != nil))
struct SampleFiles {
    @Test func write() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LONGGAME_EXPORT_DIR"] ?? "")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var run = Sample.run
        run.workout.blocks.removeLast()
        for (stem, sample) in [("ride", Sample.ride), ("run", Sample.run), ("run-timed", run)] {
            for format in WorkoutFileFormat.allCases {
                guard let data = try? format.data(for: sample) else { continue }
                try data.write(to: directory.appendingPathComponent("\(stem).\(format == .wahooPlan ? "wahoo.json" : format.fileExtension)"))
            }
        }
    }
}
