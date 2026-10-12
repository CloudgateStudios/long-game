import Analysis
import Foundation
import HealthKit

/// Reads Apple Health. Read-only: no share types are ever requested.
public struct HealthKitDataSource: HealthDataSource {
    public let workoutSource: WorkoutSource = .healthKit

    private let store = HKHealthStore()
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Authorization

    /// Exactly the types listed in the brief. Never add routes, ECG, clinical records,
    /// medications, blood pressure, glucose, nutrition, reproductive health, state of
    /// mind or audio exposure.
    static var readTypes: Set<HKObjectType> {
        let quantities: [HKQuantityTypeIdentifier] = [
            // Core
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
            // Recommended
            .vo2Max, .heartRateRecoveryOneMinute, .respiratoryRate, .activeEnergyBurned, .stepCount, .bodyMass,
            // Profile
            .height,
            // Running
            .distanceWalkingRunning, .runningSpeed, .runningPower,
            // Cycling
            .distanceCycling, .cyclingPower, .cyclingCadence, .cyclingFunctionalThresholdPower,
            // Swimming
            .distanceSwimming, .swimmingStrokeCount,
            // Effort is stored beside the workout rather than on it.
            .workoutEffortScore, .estimatedWorkoutEffortScore,
        ]
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex),
        ]
        for identifier in quantities {
            types.insert(HKQuantityType(identifier))
        }
        return types
    }

    public func needsAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        return status != .unnecessary
    }

    public func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    // MARK: Profile

    public func profile() async throws -> HealthProfileRecord {
        var record = HealthProfileRecord()
        // Characteristics throw when not set or not permitted; both just mean "unknown".
        if let components = try? store.dateOfBirthComponents() {
            record.dateOfBirth = calendar.date(from: components)
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: record.biologicalSex = .female
            case .male: record.biologicalSex = .male
            case .other: record.biologicalSex = .other
            case .notSet: break
            @unknown default: break
            }
        }
        record.heightCm = try await latest(.height)?.doubleValue(for: .meterUnit(with: .centi))
        record.weightKg = try await latest(.bodyMass)?.doubleValue(for: .gramUnit(with: .kilo))
        record.ftpWatts = try await latest(.cyclingFunctionalThresholdPower)?.doubleValue(for: .watt())
        return record
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier) async throws -> HKQuantity? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try await descriptor.result(for: store).first?.quantity
    }

    // MARK: Workouts

    public func workoutChanges(since anchor: Data?, from start: Date, onProgress: @Sendable (Int, Int) -> Void)
        async throws -> WorkoutChanges
    {
        let queryAnchor = anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: nil))],
            anchor: queryAnchor
        )
        let result = try await descriptor.result(for: store)

        // Reading each workout's heart rate is the slow part, so report as it goes.
        var records: [HealthWorkoutRecord] = []
        let total = result.addedSamples.count
        onProgress(0, total)
        for (index, workout) in result.addedSamples.enumerated() {
            records += try await self.records(for: workout)
            onProgress(index + 1, total)
        }
        return WorkoutChanges(
            upserted: records,
            deletedIDs: result.deletedObjects.map(\.uuid),
            anchor: try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        )
    }

    /// One record per workout, or one per leg for a multisport workout.
    private func records(for workout: HKWorkout) async throws -> [HealthWorkoutRecord] {
        let sourceName = workout.sourceRevision.source.name
        let effort = await effortScore(for: workout)

        let legs = workout.workoutActivities.filter {
            Self.sport(for: $0.workoutConfiguration.activityType).sport.isEndurance
        }
        if workout.workoutActivityType == .swimBikeRun, !legs.isEmpty {
            var records: [HealthWorkoutRecord] = []
            for leg in legs {
                let type = leg.workoutConfiguration.activityType
                let end = leg.endDate ?? workout.endDate
                records.append(
                    try await record(
                        id: leg.uuid,
                        sessionID: workout.uuid,
                        type: type,
                        sourceName: sourceName,
                        start: leg.startDate,
                        end: end,
                        duration: leg.duration,
                        statistics: leg.statistics(for:),
                        effort: nil
                    ))
            }
            return records
        }
        return [
            try await record(
                id: workout.uuid,
                sessionID: nil,
                type: workout.workoutActivityType,
                sourceName: sourceName,
                start: workout.startDate,
                end: workout.endDate,
                duration: workout.duration,
                statistics: workout.statistics(for:),
                effort: effort
            )
        ]
    }

    private func record(
        id: UUID,
        sessionID: UUID?,
        type: HKWorkoutActivityType,
        sourceName: String,
        start: Date,
        end: Date,
        duration: TimeInterval,
        statistics: (HKQuantityType) -> HKStatistics?,
        effort: Double?
    ) async throws -> HealthWorkoutRecord {
        let (sport, name) = Self.sport(for: type)
        func sum(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            statistics(HKQuantityType(identifier))?.sumQuantity()?.doubleValue(for: unit)
        }
        func average(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            statistics(HKQuantityType(identifier))?.averageQuantity()?.doubleValue(for: unit)
        }

        let distance: Double?
        let power: Double?
        var cadence: Double?
        switch sport {
        case .swim:
            distance = sum(.distanceSwimming, .meter())
            power = nil
        case .bike:
            distance = sum(.distanceCycling, .meter())
            power = average(.cyclingPower, .watt())
            cadence = average(.cyclingCadence, HKUnit.count().unitDivided(by: .minute()))
        case .run:
            distance = sum(.distanceWalkingRunning, .meter())
            power = average(.runningPower, .watt())
            if let steps = sum(.stepCount, .count()), duration > 0 { cadence = steps / (duration / 60) }
        case .strength:
            distance = nil
            power = nil
        case .other:
            distance = sum(.distanceWalkingRunning, .meter())
            power = nil
        }

        return HealthWorkoutRecord(
            id: id,
            sourceName: sourceName,
            sport: sport,
            activityName: name,
            sessionID: sessionID,
            start: start,
            durationSeconds: duration,
            distanceMeters: distance,
            activeEnergyKcal: sum(.activeEnergyBurned, .kilocalorie()),
            heartRate: try await heartRate(from: start, to: end),
            averagePowerWatts: power,
            averageCadence: cadence,
            effortScore: effort
        )
    }

    /// Heart rate from any source during the workout, so a ride recorded on a bike
    /// computer still gets the samples a watch took at the same time.
    private func heartRate(from start: Date, to end: Date) async throws -> [HeartRatePoint] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [
                .quantitySample(
                    type: HKQuantityType(.heartRate),
                    predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
                )
            ],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let unit = HKUnit.count().unitDivided(by: .minute())
        return try await descriptor.result(for: store).map {
            HeartRatePoint(offset: $0.startDate.timeIntervalSince(start), bpm: $0.quantity.doubleValue(for: unit))
        }
    }

    /// The rating entered on the watch, or Apple's estimate when there is none.
    private func effortScore(for workout: HKWorkout) async -> Double? {
        let descriptor = HKWorkoutEffortRelationshipQueryDescriptor(
            predicate: HKQuery.predicateForObject(with: workout.uuid),
            anchor: nil,
            option: .mostRelevant
        )
        guard let result = try? await descriptor.result(for: store) else { return nil }
        let samples = result.relationships.flatMap { $0.samples ?? [] }.compactMap { $0 as? HKQuantitySample }
        let rated = samples.first { $0.quantityType == HKQuantityType(.workoutEffortScore) } ?? samples.first
        return rated?.quantity.doubleValue(for: .appleEffortScore())
    }

    public func observeWorkouts(onChange: @escaping @Sendable () async -> Void) async throws {
        try await store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
        let query = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { _, completion, error in
            guard error == nil else {
                completion()
                return
            }
            // Health waits for the completion call before it considers the delivery handled.
            let done = UncheckedSendable(completion)
            Task {
                await onChange()
                done.value()
            }
        }
        store.execute(query)
    }

    // MARK: Daily metrics

    public func dailyMetrics(in interval: DateInterval) async throws -> [HealthDailyRecord] {
        let firstDay = calendar.startOfDay(for: interval.start)
        var days: [Date: HealthDailyRecord] = [:]
        func update(_ day: Date, _ change: (inout HealthDailyRecord) -> Void) {
            guard day >= firstDay, day <= interval.end else { return }
            change(&days[day, default: HealthDailyRecord(date: day)])
        }

        let perMinute = HKUnit.count().unitDivided(by: .minute())
        let vo2 = HKUnit(from: "ml/kg*min")
        let quantities:
            [(HKQuantityTypeIdentifier, HKStatisticsOptions, HKUnit, WritableKeyPath<HealthDailyRecord, Double?>)] = [
                (.restingHeartRate, .discreteAverage, perMinute, \.restingHR),
                (.heartRateVariabilitySDNN, .discreteAverage, .secondUnit(with: .milli), \.hrvSDNN),
                (.respiratoryRate, .discreteAverage, perMinute, \.respiratoryRate),
                (.stepCount, .cumulativeSum, .count(), \.steps),
                (.activeEnergyBurned, .cumulativeSum, .kilocalorie(), \.activeEnergyKcal),
                (.vo2Max, .discreteAverage, vo2, \.vo2Max),
                (.bodyMass, .discreteAverage, .gramUnit(with: .kilo), \.bodyMassKg),
            ]
        for (identifier, options, unit, keyPath) in quantities {
            let descriptor = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(
                    type: HKQuantityType(identifier),
                    predicate: HKQuery.predicateForSamples(withStart: firstDay, end: interval.end)
                ),
                options: options,
                anchorDate: firstDay,
                intervalComponents: DateComponents(day: 1)
            )
            // A type the user declined simply has no data; one failing type must not sink the rest.
            guard let collection = try? await descriptor.result(for: store) else { continue }
            for statistics in collection.statistics() {
                let quantity = options == .cumulativeSum ? statistics.sumQuantity() : statistics.averageQuantity()
                guard let value = quantity?.doubleValue(for: unit) else { continue }
                update(calendar.startOfDay(for: statistics.startDate)) { $0[keyPath: keyPath] = value }
            }
        }

        // Start a day early: the first night begins the evening before.
        let sleepStart = calendar.date(byAdding: .day, value: -1, to: firstDay) ?? firstDay
        let sleepDescriptor = HKSampleQueryDescriptor(
            predicates: [
                .categorySample(
                    type: HKCategoryType(.sleepAnalysis),
                    predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: interval.end)
                )
            ],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        if let samples = try? await sleepDescriptor.result(for: store) {
            let segments = samples.compactMap { sample -> SleepSegment? in
                guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
                let stage: SleepStage
                switch value {
                case .inBed: stage = .inBed
                case .asleepUnspecified: stage = .unspecified
                case .awake: stage = .awake
                case .asleepCore: stage = .core
                case .asleepDeep: stage = .deep
                case .asleepREM: stage = .rem
                @unknown default: return nil
                }
                return SleepSegment(start: sample.startDate, end: sample.endDate, stage: stage)
            }
            for (day, sleep) in SleepAggregator.summarize(segments, calendar: calendar) where sleep.asleepSeconds > 0 {
                update(day) {
                    $0.sleepSeconds = sleep.asleepSeconds
                    $0.sleepCoreSeconds = sleep.coreSeconds
                    $0.sleepDeepSeconds = sleep.deepSeconds
                    $0.sleepREMSeconds = sleep.remSeconds
                    $0.sleepAwakeSeconds = sleep.awakeSeconds
                }
            }
        }
        return days.values.sorted { $0.date < $1.date }
    }

    // MARK: Sport mapping

    /// Swim, bike and run are modelled in detail; strength is tracked; everything else
    /// is logged under its own name.
    static func sport(for type: HKWorkoutActivityType) -> (sport: Sport, name: String) {
        switch type {
        case .swimming: (.swim, "Swimming")
        case .cycling, .handCycling: (.bike, "Cycling")
        case .running: (.run, "Running")
        case .traditionalStrengthTraining: (.strength, "Traditional Strength Training")
        case .functionalStrengthTraining: (.strength, "Functional Strength Training")
        case .coreTraining: (.strength, "Core Training")
        case .walking: (.other, "Walking")
        case .hiking: (.other, "Hiking")
        case .curling: (.other, "Curling")
        case .yoga: (.other, "Yoga")
        case .pilates: (.other, "Pilates")
        case .rowing: (.other, "Rowing")
        case .elliptical: (.other, "Elliptical")
        case .stairClimbing, .stairs: (.other, "Stairs")
        case .highIntensityIntervalTraining: (.other, "HIIT")
        case .crossTraining, .mixedCardio: (.other, "Cross Training")
        case .flexibility, .cooldown, .preparationAndRecovery: (.other, "Stretching")
        case .downhillSkiing, .crossCountrySkiing, .snowboarding, .snowSports: (.other, "Snow Sports")
        case .paddleSports, .surfingSports, .waterFitness, .waterSports: (.other, "Water Sports")
        case .golf: (.other, "Golf")
        case .tennis, .pickleball, .badminton, .squash, .racquetball, .tableTennis: (.other, "Racquet Sports")
        case .soccer, .basketball, .hockey, .baseball, .volleyball, .americanFootball, .rugby: (.other, "Team Sport")
        case .climbing: (.other, "Climbing")
        case .dance, .cardioDance, .socialDance: (.other, "Dance")
        case .swimBikeRun: (.other, "Multisport")
        case .transition: (.other, "Transition")
        default: (.other, "Workout")
        }
    }
}

/// Carries Health's non-Sendable completion handler into a task.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
