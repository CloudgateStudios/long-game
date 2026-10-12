import SwiftUI

/// A strip above the tab bar on every tab saying what the app is busy with, so a long import
/// or a slow coach reply never looks like a frozen screen.
struct ActivityBanner: View {
    let activities: [AppActivity]

    var body: some View {
        if !activities.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(activities) { activity in
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(activity.text)
                            .font(.subheadline)
                            .monospacedDigit()
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 760)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// A full-height placeholder for a screen whose content is still on its way.
struct LoadingPlaceholder: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
