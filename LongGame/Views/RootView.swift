import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case today, plan, log, coach, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .log: "Log"
        case .coach: "Coach"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.max"
        case .plan: "calendar"
        case .log: "list.bullet.rectangle"
        case .coach: "bubble.left.and.text.bubble.right"
        case .settings: "gearshape"
        }
    }
}

/// Tab bar on iPhone, sidebar on iPad and Mac.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @SceneStorage("selectedSection") private var selection: AppSection = .today

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                Tab(section.title, systemImage: section.symbolName, value: section) {
                    NavigationStack {
                        content(for: section)
                            .navigationTitle(section.title)
                    }
                    // At the bottom, just above the tab bar: at the top it would cover the
                    // back button of any screen pushed inside the tab.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ActivityBanner(activities: environment.activities)
                            .animation(.default, value: environment.activities)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Opening the weekly reminder lands on the coach, which then runs the review.
        .onChange(of: environment.reminder.openedFromReminder, initial: true) { _, opened in
            if opened { selection = .coach }
        }
    }

    @ViewBuilder
    private func content(for section: AppSection) -> some View {
        switch section {
        case .today: DashboardView()
        case .plan: PlanView()
        case .log: LogView()
        case .coach: CoachView()
        case .settings: SettingsView()
        }
    }
}
