// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LongGameKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "Analysis", targets: ["Analysis"]),
        .library(name: "Models", targets: ["Models"]),
        .library(name: "HealthIngest", targets: ["HealthIngest"]),
        .library(name: "Coach", targets: ["Coach"]),
        .library(name: "WorkoutExport", targets: ["WorkoutExport"]),
    ],
    targets: [
        // Pure Swift (Foundation only). Domain value types and all deterministic rules.
        .target(name: "Analysis"),
        // SwiftData @Model types and the store factory.
        .target(name: "Models", dependencies: ["Analysis"]),
        // The only module allowed to import HealthKit.
        .target(
            name: "HealthIngest",
            dependencies: ["Analysis", "Models"],
            resources: [.process("Fixtures")]
        ),
        .target(name: "Coach", dependencies: ["Analysis", "Models"]),
        // Structured workouts as files (FIT, ZWO, MRC, ERG, Wahoo) and as WorkoutKit plans.
        .target(name: "WorkoutExport", dependencies: ["Analysis"]),
        .testTarget(name: "AnalysisTests", dependencies: ["Analysis"]),
        .testTarget(name: "ModelsTests", dependencies: ["Models"]),
        .testTarget(name: "HealthIngestTests", dependencies: ["HealthIngest", "Models"]),
        .testTarget(name: "WorkoutExportTests", dependencies: ["WorkoutExport", "Analysis"]),
        .testTarget(name: "CoachTests", dependencies: ["Coach", "Models", "Analysis", "HealthIngest"]),
    ],
    swiftLanguageModes: [.v6]
)
