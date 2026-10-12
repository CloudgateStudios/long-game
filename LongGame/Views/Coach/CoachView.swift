import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct CoachView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \CoachReview.date, order: .reverse) private var reviews: [CoachReview]
    @Query(sort: \CoachConversation.updatedAt, order: .reverse) private var conversations: [CoachConversation]
    @State private var openConversation: CoachConversation?
    @State private var renaming: NamedSession?
    @AppStorage("selectedPlanID") private var selectedPlanID = ""
    @State private var opened: CoachReview?
    @State private var exportText: String?
    @State private var previewJSON: String?
    @State private var didCopy = false
    @SceneStorage("selectedSection") private var selection: AppSection = .coach

    private var coach: CoachSession { environment.coach }
    private var planID: UUID? { UUID(uuidString: selectedPlanID) }

    /// The newest review still waiting on decisions.
    private var undecided: (review: CoachReview, count: Int)? {
        for review in reviews {
            let count = (review.suggestions ?? []).filter { $0.status == .pending }.count
            if count > 0 { return (review, count) }
        }
        return nil
    }

    /// Reviews and conversations together, newest first.
    private var history: [HistoryItem] {
        let items =
            reviews.map(HistoryItem.review)
            + conversations.filter { $0.messagesJSON != "[]" }.map(HistoryItem.conversation)
        return items.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if let undecided {
                Section {
                    NavigationLink {
                        ReviewDetailView(review: undecided.review)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(undecided.count) suggestion\(undecided.count == 1 ? "" : "s") to decide")
                                    .font(.headline)
                                Text(undecided.review.displayTitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checklist")
                        }
                    }
                    .listRowBackground(Color.accentColor.opacity(0.15))
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Weekly review").font(.headline)
                        Text(
                            coach.hasKey
                                ? "Looks at your last four weeks of training and recovery and suggests changes to the sessions ahead."
                                : "Reviews here need an Anthropic API key. Without one, Copy for Claude gives you the same data and prompt to paste into the Claude app."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    if coach.hasKey {
                        Button {
                            Task { await run(.onDemand) }
                        } label: {
                            Label(coach.isRunning ? "Reviewing…" : "Review My Training", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(coach.isRunning)
                    } else {
                        Button {
                            selection = .settings
                        } label: {
                            Label("Add API Key in Settings", systemImage: "key").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: copyForClaude) {
                            Label(
                                didCopy ? "Copied" : "Copy for Claude",
                                systemImage: didCopy ? "checkmark" : "doc.on.doc"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(action: startConversation) {
                        Label("Talk to the Coach", systemImage: "bubble.left.and.text.bubble.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coach.canChat)
                }
                .controlSize(.large)
                .padding(.vertical, 6)
            } footer: {
                if didCopy {
                    Text(
                        "Copied. Paste it into a new chat in the Claude app. Suggestions from there are applied to the plan by hand."
                    )
                }
            }

            switch coach.state {
            case .idle:
                EmptyView()
            case .running(let assessment):
                Section("Reviewing") {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(assessment.isEmpty ? "Reading your last four weeks…" : "Writing the review…")
                            Text("A review usually takes about a minute. You can leave this screen; it carries on.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !assessment.isEmpty {
                        Text(assessment)
                    }
                }
            case .failed(let error):
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error.title)
                            Text(error.explanation).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if error.isRetryable {
                        Button("Try Again") {
                            Task { opened = await coach.retry(planID: planID, in: context) }
                        }
                    }
                    Button("Dismiss") { coach.dismissError() }
                }
            }

            if history.isEmpty, coach.state == .idle {
                Section {
                    ContentUnavailableView(
                        "No reviews yet",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Reviews and conversations with the coach are kept here.")
                    )
                }
            } else if !history.isEmpty {
                Section("History") {
                    ForEach(history) { item in
                        NavigationLink {
                            switch item {
                            case .review(let review): ReviewDetailView(review: review)
                            case .conversation(let conversation): CoachChatView(conversation: conversation)
                            }
                        } label: {
                            HistoryRow(item: item)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renaming = item.named }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Rename", systemImage: "pencil") { renaming = item.named }
                        }
                    }
                    .onDelete { offsets in
                        let shown = history
                        for index in offsets {
                            switch shown[index] {
                            case .review(let review): context.delete(review)
                            case .conversation(let conversation): context.delete(conversation)
                            }
                        }
                        environment.saveChanges()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Coach Options", systemImage: "ellipsis.circle") {
                    Button(didCopy ? "Copied" : "Copy for Claude", systemImage: "doc.on.doc", action: copyForClaude)
                    Button("See What Will Be Sent", systemImage: "eye") {
                        previewJSON =
                            try? CoachPayloadBuilder.build(in: context, trigger: .onDemand, planID: planID).json
                    }
                }
            }
        }
        .readableWidth()
        .task(id: environment.reminder.openedFromReminder) {
            await startWeeklyReviewIfAsked()
        }
        .renameSession($renaming)
        .navigationDestination(item: $openConversation) { conversation in
            CoachChatView(conversation: conversation)
        }
        .navigationDestination(item: $opened) { review in
            ReviewDetailView(review: review)
        }
        .sheet(item: Binding(get: { previewJSON.map(IdentifiedText.init) }, set: { previewJSON = $0?.text })) { item in
            NavigationStack {
                PayloadView(json: item.text)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { previewJSON = nil }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
    }

    /// Runs the weekly review when the app was opened from its reminder. A review already
    /// done today is opened instead of paying for another.
    private func startWeeklyReviewIfAsked() async {
        guard environment.reminder.openedFromReminder else { return }
        environment.reminder.openedFromReminder = false
        if let latest = reviews.first(where: { $0.trigger != .planGeneration }),
            Calendar.current.isDateInToday(latest.date)
        {
            opened = latest
        } else if coach.hasKey {
            await run(.weekly)
        }
    }

    private func startConversation() {
        let conversation = CoachConversation(kind: .discussion)
        context.insert(conversation)
        openConversation = conversation
    }

    private func run(_ trigger: ReviewTrigger) async {
        opened = await coach.run(trigger, planID: planID, in: context)
    }

    /// Puts the prompt and payload on the clipboard. The copy expires so health data
    /// does not sit there indefinitely.
    private func copyForClaude() {
        guard let built = try? CoachPayloadBuilder.build(in: context, trigger: .onDemand, planID: planID) else {
            return
        }
        let text = CoachPayloadBuilder.exportText(for: built)
        #if os(iOS)
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.expirationDate: Date().addingTimeInterval(600)]
        )
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(8))
            didCopy = false
        }
    }
}

private struct IdentifiedText: Identifiable {
    let text: String
    var id: Int { text.hashValue }
}

/// A review or a conversation, so both can sit in one dated list.
private enum HistoryItem: Identifiable {
    case review(CoachReview)
    case conversation(CoachConversation)

    var id: UUID { named.id }

    var date: Date {
        switch self {
        case .review(let review): review.date
        case .conversation(let conversation): conversation.updatedAt
        }
    }

    var named: NamedSession {
        switch self {
        case .review(let review): .review(review)
        case .conversation(let conversation): .conversation(conversation)
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    private var title: String {
        switch item {
        case .review(let review): review.displayTitle
        case .conversation(let conversation): conversation.title.isEmpty ? "Conversation" : conversation.title
        }
    }

    private var kind: String {
        switch item {
        case .review: "Review"
        case .conversation(let conversation): conversation.kind == .interview ? "Plan interview" : "Conversation"
        }
    }

    private var pending: Int {
        guard case .review(let review) = item else { return 0 }
        return (review.suggestions ?? []).filter { $0.status == .pending }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).lineLimit(2)
                Spacer()
                if pending > 0 {
                    Chip(text: "\(pending) to decide", tint: .accentColor, isFilled: true)
                }
            }
            Text("\(kind) · \(item.date.formatted(.dateTime.weekday().day().month()))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if case .review(let review) = item {
                Text(review.assessment).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// The exact JSON sent (or about to be sent) to the model, laid out for reading.
struct PayloadView: View {
    let json: String

    private var pretty: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "This is everything the coach receives, along with its instructions. It contains no name, date of birth, location, device or app names."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text(pretty)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle("What Was Sent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
