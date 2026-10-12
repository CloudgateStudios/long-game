import Analysis
import Coach
import Models
import SwiftData
import SwiftUI

/// A conversation with the coach: an interview that ends in a draft plan, or an open
/// discussion. Proposals appear inline as cards and change nothing until accepted.
struct CoachChatView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Query private var plans: [TrainingPlan]
    @AppStorage("selectedPlanID") private var selectedPlanID = ""

    let conversation: CoachConversation

    @State private var draft = ""
    @State private var composerID = UUID()
    @State private var renaming: NamedSession?
    @State private var reviewingDraft: TrainingPlan?
    @FocusState private var isTyping: Bool

    private static let bottomID = "bottom"
    private static let interviewOpening = "I'd like to set up a training plan."

    private var coach: CoachSession { environment.coach }
    private var isSending: Bool { coach.sendingConversations.contains(conversation.uuid) }
    /// The coach's reply so far while it streams.
    private var streaming: String { coach.streamingReplies[conversation.uuid] ?? "" }
    private var failure: CoachError? { coach.chatFailures[conversation.uuid] }
    private var items: [ChatItem] { CoachChat.transcript(of: conversation.messagesJSON) }
    private var draftPlan: TrainingPlan? {
        plans.first { $0.uuid == conversation.draftPlanID && $0.isDraft }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty, !isSending, failure == nil {
                        intro
                    }
                    ForEach(items) { item in
                        row(for: item)
                    }
                    if isSending {
                        if streaming.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(items.isEmpty ? "Coach is reading your training data…" : "Coach is thinking…")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(.vertical, 4)
                        } else {
                            Bubble(text: streaming, isAthlete: false)
                        }
                    }
                    if let failure {
                        failureRow(failure)
                    } else if isAwaitingReply, !isSending {
                        resumeRow
                    }
                    if conversation.estimatedCost > 0, !isSending {
                        Text(
                            "This conversation has cost about \(conversation.estimatedCost.formatted(.currency(code: "USD").precision(.fractionLength(2)))) so far."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: items.count) { scrollToEnd(proxy) }
            .onChange(of: streaming) { scrollToEnd(proxy) }
            .onChange(of: isSending) { scrollToEnd(proxy) }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(
            conversation.isTitleSettled
                ? conversation.title : (conversation.kind == .interview ? "Plan with the Coach" : "Coach")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename", systemImage: "pencil") { renaming = .conversation(conversation) }
                    .disabled(conversation.messagesJSON == "[]")
            }
        }
        .renameSession($renaming)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $reviewingDraft) { plan in
            DraftPlanView(draft: plan) { selectedPlanID = $0.uuid.uuidString }
        }
        .onDisappear {
            if coach.visibleConversation == conversation.uuid { coach.visibleConversation = nil }
        }
        .onAppear {
            coach.visibleConversation = conversation.uuid
            // Started with a plain Task rather than `.task`, which would cancel the request
            // the moment this screen is left.
            Task {
                if conversation.kind == .interview, conversation.messagesJSON == "[]", coach.canChat {
                    // An interview opens itself: the coach speaks first.
                    await send(Self.interviewOpening)
                } else if isAwaitingReply, failure == nil, coach.canChat {
                    // A message sent earlier never got its answer (the app was closed or
                    // lost its connection), so ask again without making the user do it.
                    await send(nil)
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                conversation.kind == .interview
                    ? "The coach will ask a few questions, then draft a plan."
                    : "Ask about your training, or say what needs to change."
            )
            .font(.headline)
            Text(
                coach.canChat
                    ? "The coach sees your last four weeks of workouts and recovery, your goals and your plan. Anything it proposes shows up here for you to accept or reject."
                    : "Add an Anthropic API key in Settings to talk to the coach."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func row(for item: ChatItem) -> some View {
        switch item {
        case .athlete(_, let text):
            Bubble(text: text, isAthlete: true)
        case .coach(_, let text):
            Bubble(text: text, isAthlete: false)
        case .suggestions(_, let toolUseID):
            let cards = (conversation.suggestions ?? []).filter { $0.sourceID == toolUseID }.sorted {
                $0.createdAt < $1.createdAt
            }
            ForEach(cards) { suggestion in
                SuggestionCard(suggestion: suggestion)
                    .padding(12)
                    .background(.cardBackground, in: .rect(cornerRadius: 16))
            }
        case .draftPlan:
            if let draftPlan {
                Button {
                    reviewingDraft = draftPlan
                } label: {
                    HStack {
                        Label("Review Draft Plan", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\((draftPlan.workouts ?? []).count) sessions").font(.subheadline).foregroundStyle(
                            .secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Label(
                    "The coach drafted a plan here. It has since been accepted, replaced or discarded.",
                    systemImage: "sparkles"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        case .saved(_, let text):
            Label(text, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func failureRow(_ error: CoachError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                    Text(error.explanation).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            // The message was kept, so trying again does not mean typing it again.
            Button("Try Again") {
                Task { await send(nil) }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.cardBackground, in: .rect(cornerRadius: 16))
    }

    /// The last message has no reply and nothing is in progress.
    private var isAwaitingReply: Bool { CoachChat.isAwaitingReply(conversation.messagesJSON) }

    private var resumeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The coach hasn't answered this yet.")
            Text("Your message was saved.").font(.subheadline).foregroundStyle(.secondary)
            Button("Get the Reply") {
                Task { await send(nil) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!coach.canChat)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.cardBackground, in: .rect(cornerRadius: 16))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the coach", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.cardBackground, in: .rect(cornerRadius: 20))
                .focused($isTyping)
                .onSubmit(submit)
                #if os(macOS)
            // On the Mac the field is rebuilt after each send, which guarantees it is empty.
            .id(composerID)
                #endif
            if isSending {
                ProgressView()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Waiting for the coach")
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: submit)
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .disabled(!canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var canSend: Bool {
        coach.canChat && !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        // A multi-line text field can write its own contents back when it is cleared in
        // the same pass as the submit, leaving the sent text sitting in the field. Clearing
        // again on the next turn of the run loop makes it stick.
        Task { @MainActor in
            draft = ""
            composerID = UUID()
            #if os(macOS)
            isTyping = true
            #endif
            await send(text)
        }
    }

    private func send(_ text: String?) async {
        await coach.sendChat(text, in: conversation, context: context)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}

private struct Bubble: View {
    let text: String
    let isAthlete: Bool

    var body: some View {
        HStack {
            if isAthlete { Spacer(minLength: 40) }
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(isAthlete ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    isAthlete ? AnyShapeStyle(.tint) : AnyShapeStyle(.cardBackground), in: .rect(cornerRadius: 18))
            if !isAthlete { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isAthlete ? "You" : "Coach"): \(text)")
    }
}
