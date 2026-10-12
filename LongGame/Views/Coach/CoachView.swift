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

    private var coach: CoachSession { environment.coach }
    private var planID: UUID? { UUID(uuidString: selectedPlanID) }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await run(.onDemand) }
                } label: {
                    Label(coach.isRunning ? "Reviewing…" : "Review My Training", systemImage: "sparkles")
                }
                .disabled(!coach.hasKey || coach.isRunning)

                Button {
                    let conversation = CoachConversation(kind: .discussion)
                    context.insert(conversation)
                    openConversation = conversation
                } label: {
                    Label("Talk to the Coach", systemImage: "bubble.left.and.text.bubble.right")
                }
                .disabled(!coach.canChat)

                Button {
                    copyForClaude()
                } label: {
                    Label(didCopy ? "Copied" : "Copy for Claude", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                Button {
                    previewJSON = try? CoachPayloadBuilder.build(in: context, trigger: .onDemand, planID: planID).json
                } label: {
                    Label("See What Will Be Sent", systemImage: "eye")
                }
            } footer: {
                if !coach.hasKey {
                    Text(
                        "Add an Anthropic API key in Settings to run reviews here. Copy for Claude needs no key: it copies the same data and prompt for you to paste into the Claude app."
                    )
                } else if didCopy {
                    Text(
                        "Paste it into a new chat in the Claude app. Suggestions from there are applied to the plan by hand."
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

            if reviews.isEmpty, conversations.allSatisfy({ $0.messagesJSON == "[]" }), coach.state == .idle {
                Section {
                    ContentUnavailableView(
                        "No reviews yet",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(
                            "A review looks at your last four weeks of training and recovery and suggests changes to the sessions ahead. Or talk to the coach to ask questions and say what needs to change."
                        )
                    )
                }
            }

            if conversations.contains(where: { $0.messagesJSON != "[]" }) {
                Section("Conversations") {
                    ForEach(conversations.filter { $0.messagesJSON != "[]" }) { conversation in
                        NavigationLink {
                            CoachChatView(conversation: conversation)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title.isEmpty ? "Conversation" : conversation.title).lineLimit(2)
                                Text(
                                    "\(conversation.kind == .interview ? "Plan interview" : "Discussion") · \(conversation.updatedAt.formatted(.dateTime.weekday().day().month()))"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renaming = .conversation(conversation) }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Rename", systemImage: "pencil") { renaming = .conversation(conversation) }
                        }
                    }
                    .onDelete { offsets in
                        let shown = conversations.filter { $0.messagesJSON != "[]" }
                        for index in offsets { context.delete(shown[index]) }
                        environment.saveChanges()
                    }
                }
            }

            if !reviews.isEmpty {
                Section("Reviews") {
                    ForEach(reviews) { review in
                        NavigationLink {
                            ReviewDetailView(review: review)
                        } label: {
                            ReviewRow(review: review)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renaming = .review(review) }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Rename", systemImage: "pencil") { renaming = .review(review) }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(reviews[index]) }
                        environment.saveChanges()
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

private struct ReviewRow: View {
    let review: CoachReview

    private var pending: Int {
        (review.suggestions ?? []).filter { $0.status == .pending }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(review.displayTitle).lineLimit(2)
                Spacer()
                if pending > 0 {
                    Text("\(pending) to decide")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: .capsule)
                }
            }
            // A named review still says when it was; an unnamed one is already listed by date.
            Text(
                review.title.isEmpty
                    ? review.assessment
                    : "\(review.date.formatted(.dateTime.weekday().day().month())) · \(review.assessment)"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
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
