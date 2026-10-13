import SwiftUI

/// When the weekly review reminder fires. Changes apply as they are made.
struct ReminderSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var reminder: WeeklyReminder { environment.reminder }

    private var time: Binding<Date> {
        Binding {
            reminder.time
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            apply(minute: (parts.hour ?? 18) * 60 + (parts.minute ?? 0))
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Remind me", isOn: Binding(get: { reminder.isEnabled }, set: { apply(enabled: $0) }))
                if reminder.isEnabled {
                    Picker("Day", selection: Binding(get: { reminder.weekday }, set: { apply(weekday: $0) })) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                }
            } footer: {
                if reminder.isDenied {
                    Text(
                        "Notifications are turned off for Long Game. Allow them in system settings to use the reminder."
                    )
                } else {
                    Text(
                        "Opening the app from the reminder starts that week's review. Without an API key it just opens the Coach tab."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .navigationTitle("Weekly Review")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func apply(enabled: Bool? = nil, weekday: Int? = nil, minute: Int? = nil) {
        Task {
            await reminder.update(
                enabled: enabled ?? reminder.isEnabled,
                weekday: weekday ?? reminder.weekday,
                minuteOfDay: minute ?? reminder.minuteOfDay
            )
        }
    }
}

extension WeeklyReminder {
    /// The time of day the reminder fires, on today's date.
    var time: Date {
        Calendar.current.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: .now) ?? .now
    }
}
