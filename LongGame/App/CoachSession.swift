import Analysis
import Coach
import Foundation
import Models
import Observation
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Coach state for the UI: whether a key is set, which model is chosen, and the review
/// in progress.
@Observable
final class CoachSession {
    enum State: Equatable {
        case idle
        /// Holds the assessment so far; empty while the model is still thinking.
        case running(assessment: String)
        case failed(CoachError)
    }

    private(set) var state: State = .idle
    private var isWritingPlan = false
    /// Conversations with a message on its way or a reply coming back.
    private(set) var sendingConversations: Set<UUID> = []
    /// The coach's reply so far, per conversation, while it streams.
    private(set) var streamingReplies: [UUID: String] = [:]
    private(set) var chatFailures: [UUID: CoachError] = [:]
    /// The conversation on screen, which shows its own progress and needs no banner.
    var visibleConversation: UUID?
    private(set) var hasKey = false
    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: Self.modelKey) }
    }

    private let keyStore: any APIKeyStore
    private let reviewer = CoachReviewer()
    private let planner = CoachPlanner()
    private let liveChat = CoachChat()
    /// In sample-data mode with no key, chat talks to a canned stand-in instead of the API.
    private let sampleChat: CoachChat?

    /// Whether a conversation can be started: a key is set, or the sample coach is standing in.
    var canChat: Bool { hasKey || sampleChat != nil }
    /// Sessions written so far while a plan is being generated.
    private(set) var plannedSessionCount = 0
    private var lastTrigger: ReviewTrigger = .onDemand
    private static let modelKey = "coachModel"

    init() {
        sampleChat = AppEnvironment.usesFixture
            ? CoachChat(client: ClaudeClient(transport: SampleCoachTransport(), retryDelays: []))
            : nil
        keyStore = KeychainAPIKeyStore(service: Bundle.main.bundleIdentifier ?? "LongGame")
        let stored = UserDefaults.standard.string(forKey: Self.modelKey)
        modelID = stored.flatMap(CoachConfiguration.model)?.id ?? CoachConfiguration.defaultModel
        refreshKey()
    }

    /// The key can arrive later through iCloud Keychain, so this is re-checked on activation.
    func refreshKey() {
        hasKey = keyStore.read() != nil
    }

    /// Saves the key, or removes it when empty. Returns false if the Keychain refused.
    @discardableResult
    func saveKey(_ key: String?) -> Bool {
        let saved = (try? keyStore.save(key)) != nil
        refreshKey()
        return saved
    }

    /// A review, plan or chat reply is in flight.
    var isBusy: Bool { isRunning || !sendingConversations.isEmpty }

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    /// Runs a review and returns it, or nil if it failed (the reason is in `state`).
    func run(_ trigger: ReviewTrigger, planID: UUID?, in context: ModelContext) async -> CoachReview? {
        guard !isRunning else { return nil }
        lastTrigger = trigger
        state = .running(assessment: "")
        let background = BackgroundTime()
        defer { background.end() }
        do {
            let review = try await reviewer.run(trigger: trigger, model: modelID, apiKey: keyStore.read(), planID: planID, in: context) { [weak self] text in
                self?.state = .running(assessment: text)
            }
            state = .idle
            return review
        } catch let error as CoachError {
            state = .failed(error)
        } catch {
            state = .failed(.malformed)
        }
        return nil
    }

    /// Asks the coach for a plan and returns it as a draft, or nil if it failed.
    func generatePlan(_ request: PlanRequest, goal: Goal?, in context: ModelContext) async -> TrainingPlan? {
        guard !isRunning else { return nil }
        plannedSessionCount = 0
        isWritingPlan = true
        defer { isWritingPlan = false }
        state = .running(assessment: "")
        let background = BackgroundTime()
        defer { background.end() }
        do {
            let plan = try await planner.generate(request: request, goal: goal, model: modelID, apiKey: keyStore.read(), in: context) { [weak self] progress in
                self?.plannedSessionCount = progress.sessionCount
                self?.state = .running(assessment: progress.summary)
            }
            state = .idle
            return plan
        } catch let error as CoachError {
            state = .failed(error)
        } catch {
            state = .failed(.malformed)
        }
        return nil
    }

    func retry(planID: UUID?, in context: ModelContext) async -> CoachReview? {
        await run(lastTrigger, planID: planID, in: context)
    }

    /// Sends a chat message (or, with nil, picks up after a failure). The state lives
    /// here rather than in the chat screen, so leaving the screen does not lose track of it.
    func sendChat(_ text: String?, in conversation: CoachConversation, context: ModelContext) async {
        let id = conversation.uuid
        guard !sendingConversations.contains(id) else { return }
        sendingConversations.insert(id)
        chatFailures[id] = nil
        streamingReplies[id] = ""
        // A real key always wins; the stand-in is only for sample-data mode without one.
        let key = keyStore.read()
        let (chat, apiKey) = key == nil && sampleChat != nil ? (sampleChat ?? liveChat, "sample") : (liveChat, key)
        let background = BackgroundTime()
        defer { background.end() }
        do {
            try await chat.send(text, in: conversation, model: modelID, apiKey: apiKey, context: context) { [weak self] partial in
                self?.streamingReplies[id] = partial
            }
        } catch let error as CoachError {
            chatFailures[id] = error
        } catch {
            chatFailures[id] = .malformed
        }
        streamingReplies[id] = nil
        sendingConversations.remove(id)
        // Once there is a first exchange, ask for a better name than the opening words.
        // Done on the side so it never holds up the conversation.
        if chatFailures[id] == nil, key != nil, !conversation.isTitleSettled {
            Task { await liveChat.suggestTitle(for: conversation, apiKey: key, context: context) }
        }
    }

    /// One line describing what the coach is doing, for the app-wide banner.
    var activityText: String? {
        if isRunning {
            if isWritingPlan {
                return plannedSessionCount > 0 ? "Coach is writing your plan: \(plannedSessionCount) sessions so far" : "Coach is writing your plan…"
            }
            return "Coach is reviewing your training…"
        }
        if let id = sendingConversations.first(where: { $0 != visibleConversation }) {
            return (streamingReplies[id] ?? "").isEmpty ? "Coach is thinking…" : "Coach is replying…"
        }
        return nil
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }
}

/// Asks iOS for extra time when the app leaves the foreground, so a coach request in
/// flight can finish instead of being cut off the moment the user switches away. iOS
/// grants roughly half a minute; a request still running after that fails and can be resumed.
struct BackgroundTime {
    #if os(iOS)
    private let id: UIBackgroundTaskIdentifier

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Coach request")
    }

    func end() {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }
    #else
    func end() {}
    #endif
}

extension CoachError {
    var title: String {
        switch self {
        case .missingAPIKey: "No API key"
        case .offline: "You're offline"
        case .timedOut: "The request timed out"
        case .unauthorized: "The API key was rejected"
        case .rateLimited: "Too many requests"
        case .overloaded: "Claude is busy"
        case .api: "The request failed"
        case .refused: "The coach declined this request"
        case .truncated: "The reply was cut off"
        case .malformed: "The reply could not be read"
        }
    }

    var explanation: String {
        switch self {
        case .missingAPIKey: "Add your Anthropic API key in Settings, or use Copy for Claude."
        case .offline: "Check your connection and try again. Nothing was saved."
        case .timedOut: "No reply arrived in time. Nothing was saved."
        case .unauthorized: "Check the key in Settings. It may have been revoked or mistyped."
        case .rateLimited: "Wait a moment and try again."
        case .overloaded: "The service is temporarily overloaded. Try again shortly."
        case .api(let status, let message): message.isEmpty ? "The service returned an error (\(status))." : message
        case .refused: "Nothing was saved. You can use Copy for Claude instead."
        case .truncated, .malformed: "Nothing was saved. Try again."
        }
    }
}
