import Analysis
import Models
import SwiftData
import SwiftUI

/// Heart-rate and power settings that zones and training load are built from. Anything
/// left blank is derived from Health data; anything typed here wins.
struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \AthleteProfile.createdAt) private var profiles: [AthleteProfile]

    @State private var maxHR: Double?
    @State private var restingHR: Double?
    @State private var ftp: Double?
    @State private var thresholdPace = ""
    @State private var runTargets = RunTargetMode.heartRate
    @State private var usesCustomZones = false
    @State private var customBounds: [Double?] = [nil, nil, nil, nil]
    @State private var coachNotes = ""
    @State private var zones = ResolvedZones()
    @State private var didLoad = false

    private var profile: AthleteProfile? { profiles.first }

    var body: some View {
        Form {
            Section {
                numberField("Max heart rate", value: $maxHR, unit: "bpm", placeholder: derivedMaxText)
                numberField("Resting heart rate", value: $restingHR, unit: "bpm", placeholder: derivedRestingText)
            } header: {
                Text("Heart rate")
            } footer: {
                Text("Leave a field blank to use the value worked out from your Health data.")
            }

            Section {
                Toggle("Set zones by hand", isOn: $usesCustomZones)
                if usesCustomZones {
                    ForEach(0..<4, id: \.self) { index in
                        numberField(
                            "Top of zone \(index + 1)", value: $customBounds[index], unit: "bpm", placeholder: "")
                    }
                    if !customZonesAreValid {
                        Label(
                            "Enter four rising values to use these zones.", systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                if let bounds = zones.bounds {
                    ForEach(0..<5, id: \.self) { zone in
                        LabeledContent("Zone \(zone + 1)", value: rangeText(zone: zone, bounds: bounds))
                    }
                } else {
                    Text("Zones appear once a max heart rate is known.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Zones in use")
            } footer: {
                if !zones.isOverridden, zones.bounds != nil {
                    Text(
                        zones.restingHR == nil
                            ? "Worked out as percentages of max heart rate."
                            : "Worked out from heart-rate reserve (max minus resting).")
                }
            }

            Section {
                numberField("FTP", value: $ftp, unit: "W", placeholder: "Not set")
            } header: {
                Text("Cycling")
            } footer: {
                Text("With FTP set, rides that have power are scored on power instead of heart rate.")
            }

            Section {
                LabeledContent("Threshold pace") {
                    HStack {
                        TextField("Not set", text: $thresholdPace)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                            #endif
                        Text(PaceEntry.unitLabel).foregroundStyle(.secondary)
                    }
                }
                Picker("Structured runs by", selection: $runTargets) {
                    ForEach(RunTargetMode.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Running")
            } footer: {
                Text(
                    "Threshold pace is what you could hold for about an hour, entered as minutes:seconds. It lets a run's steps be shown by pace or by heart-rate zone; each session can also choose its own."
                )
            }

            Section {
                TextField("Injuries, constraints, preferences", text: $coachNotes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Notes for the coach")
            } footer: {
                Text(
                    "Sent with every review. For example: \"left knee is sore after long descents\" or \"no swimming on Fridays\"."
                )
            }

            if let profile {
                Section("From Health") {
                    if let age = profile.age() { LabeledContent("Age", value: age.formatted()) }
                    if let height = profile.heightCm {
                        LabeledContent(
                            "Height",
                            value: Measurement(value: height, unit: UnitLength.centimeters).formatted(
                                .measurement(width: .abbreviated, usage: .personHeight)))
                    }
                    if let weight = profile.weightKg {
                        LabeledContent(
                            "Weight",
                            value: Measurement(value: weight, unit: UnitMass.kilograms).formatted(
                                .measurement(
                                    width: .abbreviated, usage: .personWeight,
                                    numberFormatStyle: .number.precision(.fractionLength(0...1)))))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .navigationTitle("Athlete Profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: load)
        // Notes are saved once on the way out rather than on every keystroke.
        .onDisappear { environment.saveChanges() }
        .onChange(of: maxHR) { apply() }
        .onChange(of: restingHR) { apply() }
        .onChange(of: ftp) { apply() }
        .onChange(of: thresholdPace) { apply() }
        .onChange(of: runTargets) { apply() }
        .onChange(of: usesCustomZones) { apply() }
        .onChange(of: customBounds) { apply() }
        .onChange(of: coachNotes) {
            if didLoad { profile?.coachNotes = coachNotes }
        }
    }

    private func numberField(_ title: String, value: Binding<Double?>, unit: String, placeholder: String) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(placeholder, value: value, format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                .keyboardType(.numberPad)
                    #endif
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private var customZonesAreValid: Bool {
        HeartRateZones.isValid(customBounds.compactMap { $0 })
    }

    private var derivedMaxText: String {
        guard maxHR == nil, let value = zones.maxHR else { return "" }
        let source = zones.maxHRSource == .observed ? "highest seen" : "from age"
        return "\(Format.load(value)) (\(source))"
    }

    private var derivedRestingText: String {
        guard restingHR == nil, let value = zones.restingHR else { return "" }
        return "\(Format.load(value)) (4-week average)"
    }

    private func rangeText(zone: Int, bounds: [Double]) -> String {
        if zone == 0 { return "up to \(Format.load(bounds[0])) bpm" }
        if zone == bounds.count { return "above \(Format.load(bounds[zone - 1])) bpm" }
        return "\(Format.load(bounds[zone - 1] + 1))–\(Format.load(bounds[zone])) bpm"
    }

    private func load() {
        guard !didLoad else { return }
        if profile == nil { context.insert(AthleteProfile()) }
        if let profile {
            maxHR = profile.maxHR
            restingHR = profile.restingHRBaseline
            ftp = profile.ftpWatts
            thresholdPace = profile.thresholdRunPaceSecondsPerKm.map(PaceEntry.text) ?? ""
            runTargets = profile.runTargets
            coachNotes = profile.coachNotes
            if let override = profile.zoneUpperBoundsOverride, HeartRateZones.isValid(override) {
                usesCustomZones = true
                customBounds = override.map(Optional.some)
            }
        }
        didLoad = true
        refreshZones()
    }

    /// Saves each change as it is made and re-scores every workout against it.
    private func apply() {
        guard didLoad, let profile else { return }
        profile.maxHR = maxHR.flatMap { $0 > 0 ? $0 : nil }
        profile.restingHRBaseline = restingHR.flatMap { $0 > 0 ? $0 : nil }
        profile.ftpWatts = ftp.flatMap { $0 > 0 ? $0 : nil }
        // A half-typed pace is not saved over a good one, but clearing the field clears it.
        if let pace = PaceEntry.secondsPerKm(from: thresholdPace) {
            profile.thresholdRunPaceSecondsPerKm = pace
        } else if thresholdPace.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.thresholdRunPaceSecondsPerKm = nil
        }
        profile.runTargets = runTargets
        profile.zoneUpperBoundsOverride = usesCustomZones && customZonesAreValid ? customBounds.compactMap { $0 } : nil
        environment.reconcilePlan()
        refreshZones()
    }

    private func refreshZones() {
        zones = (try? LoadRecalculator.resolveZones(in: context)) ?? ResolvedZones()
    }
}
