import SwiftData
import SwiftUI

#if os(iOS)
import UIKit
#endif

@main
struct LongGameApp: App {
    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        // Started here rather than from a view so a background launch for a new workout,
        // which never shows a window, still registers for Health updates.
        Task { await environment.activate() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = environment.container {
                    RootView()
                        .modelContainer(container)
                } else if environment.isForcingCloudSync {
                    LoadingPlaceholder(
                        title: "Syncing with iCloud",
                        detail: "Sending your changes and checking for new data. This usually takes a few seconds.")
                } else {
                    ContentUnavailableView(
                        "Unlock to continue",
                        systemImage: "lock",
                        description: Text("Your training data is protected while this device is locked.")
                    )
                }
            }
            .environment(environment)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await environment.activate() }
                }
            }
            #if os(iOS)
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            ) { _ in
                Task { await environment.activate() }
            }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 780)
        #endif

        #if os(macOS)
        Settings {
            Group {
                if let container = environment.container {
                    SettingsScreen()
                        .modelContainer(container)
                } else {
                    ProgressView()
                }
            }
            .environment(environment)
            .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 560)
        }
        #endif
    }
}
