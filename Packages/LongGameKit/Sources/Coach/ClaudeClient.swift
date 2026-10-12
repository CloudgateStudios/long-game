import Foundation

public enum CoachError: Error, Equatable, Sendable {
    case missingAPIKey
    case offline
    case timedOut
    /// The key was rejected.
    case unauthorized
    case rateLimited
    case overloaded
    case api(status: Int, message: String)
    /// The model declined the request.
    case refused
    /// The reply was cut off before it finished.
    case truncated
    /// The reply did not match the expected structure.
    case malformed

    /// Whether trying again unchanged could succeed.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .rateLimited, .overloaded, .truncated, .malformed: true
        case .api(let status, _): status >= 500
        case .missingAPIKey, .unauthorized, .refused: false
        }
    }
}

public struct ClaudeUsage: Sendable, Equatable {
    /// Every input token, including those read from or written to the prompt cache.
    public var inputTokens = 0
    public var outputTokens = 0
    /// The part of `inputTokens` served from the cache, billed at a fraction of the price.
    public var cacheReadTokens = 0
    /// The part of `inputTokens` written to the cache, billed at a small premium.
    public var cacheWriteTokens = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// One assistant turn of a conversation, with its content blocks exactly as returned.
public struct AssistantTurn: Sendable, Equatable {
    public var content: [JSONValue]
    public var model: String
    public var stopReason: String?
    public var usage: ClaudeUsage

    /// The visible text of the turn.
    public var text: String {
        content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n\n")
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
            return (id, name, block["input"] ?? .object([:]))
        }
    }
}

public struct ClaudeMessage: Sendable, Equatable {
    public var text: String
    /// The model that produced the reply, which can differ from the one asked for when a fallback ran.
    public var model: String
    public var stopReason: String?
    public var usage: ClaudeUsage
}

/// The network seam, so the client can be tested without a network.
public protocol HTTPTransport: Sendable {
    /// Sends the request and returns the status with the body as lines as they arrive.
    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        // Ephemeral: nothing about a request or its reply is cached to disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CoachConfiguration.idleTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, lines)
    }
}

/// A minimal streaming client for the Claude Messages API. There is no official Swift
/// SDK, so this speaks the HTTP API directly.
public struct ClaudeClient: Sendable {
    private let transport: any HTTPTransport
    private let retryDelays: [Duration]

    public init(transport: any HTTPTransport = URLSessionTransport(), retryDelays: [Duration] = [.seconds(1), .seconds(3)]) {
        self.transport = transport
        self.retryDelays = Array(retryDelays.prefix(CoachConfiguration.maxRetries))
    }

    /// The structure a reply is constrained to.
    public enum ReplyFormat: Sendable {
        case review
        case plan
        case title
        case workoutStructure

        var schema: [String: Any] {
            switch self {
            case .review: CoachResponse.schema
            case .plan: PlanResponse.schema
            case .workoutStructure: WorkoutStructurer.schema
            case .title:
                ["type": "object", "additionalProperties": false, "required": ["title"], "properties": ["title": ["type": "string"]]]
            }
        }
    }

    /// Sends one user message and returns the reply, constrained to `format`. `onText`
    /// receives the text so far each time more arrives.
    public func send(
        apiKey: String,
        model: String,
        system: String,
        user: String,
        format: ReplyFormat = .review,
        effort: String = CoachConfiguration.effort,
        onText: @Sendable (String) async -> Void = { _ in }
    ) async throws -> ClaudeMessage {
        let request = try Self.request(apiKey: apiKey, model: model, system: system, user: user, schema: format.schema, effort: effort)
        var attempt = 0
        while true {
            let received = Received()
            do {
                return try await stream(request, received: received, onText: onText)
            } catch let error as CoachError {
                // Only retry while nothing has been shown, so text never restarts mid-read.
                let canRetry = error.isRetryable && error != .truncated && error != .malformed
                guard canRetry, await received.isEmpty, attempt < retryDelays.count else { throw error }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// Sends a whole conversation and returns the assistant's next turn. `messages` must
    /// be the history exactly as it was sent and received before, with only new messages
    /// added at the end. `onText` receives the visible text so far as it streams.
    public func converse(
        apiKey: String,
        model: String,
        system: String,
        messages: [JSONValue],
        tools: [JSONValue],
        onText: @Sendable (String) async -> Void = { _ in }
    ) async throws -> AssistantTurn {
        let request = try Self.conversationRequest(apiKey: apiKey, model: model, system: system, messages: messages, tools: tools)
        var attempt = 0
        while true {
            let received = Received()
            do {
                return try await streamTurn(request, received: received, onText: onText)
            } catch let error as CoachError {
                let canRetry = error.isRetryable && error != .truncated && error != .malformed
                guard canRetry, await received.isEmpty, attempt < retryDelays.count else { throw error }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    static func conversationRequest(apiKey: String, model: String, system: String, messages: [JSONValue], tools: [JSONValue]) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CoachError.missingAPIKey }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(CoachConfiguration.maxTokens)),
            "stream": .bool(true),
            "system": .string(system),
            "messages": .array(messages),
            "tools": .array(tools),
            "output_config": .object(["effort": .string(CoachConfiguration.chatEffort)]),
            // The long shared prefix (instructions, tools, training data, earlier turns) is
            // cached, so each further turn pays full price only for what is new.
            "cache_control": .object(["type": .string("ephemeral")]),
        ]
        var request = URLRequest(url: CoachConfiguration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(CoachConfiguration.apiVersion, forHTTPHeaderField: "anthropic-version")
        if CoachConfiguration.model(model)?.supportsFallback == true {
            body["fallbacks"] = .string("default")
            request.setValue(CoachConfiguration.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = Data(JSONValue.object(body).text.utf8)
        return request
    }

    /// Rebuilds the turn's content blocks from the stream. Blocks are kept as generic
    /// JSON so thinking blocks and their signatures go back to the API untouched.
    private func streamTurn(_ request: URLRequest, received: Received, onText: @Sendable (String) async -> Void) async throws -> AssistantTurn {
        let status: Int
        let lines: AsyncThrowingStream<String, Error>
        do {
            (status, lines) = try await transport.send(request)
        } catch {
            throw Self.map(error)
        }
        guard status == 200 else {
            var body = ""
            for try await line in lines { body += line }
            throw Self.error(status: status, body: body)
        }

        var turn = AssistantTurn(content: [], model: "", stopReason: nil, usage: ClaudeUsage())
        var blocks: [Int: [String: JSONValue]] = [:]
        var partialInputs: [Int: String] = [:]
        do {
            for try await line in lines {
                guard line.hasPrefix("data:"), let event = JSONValue.parse(String(line.dropFirst(5))) else { continue }
                let index = event["index"]?.number.map(Int.init)
                switch event["type"]?.string {
                case "message_start":
                    turn.model = event["message"]?["model"]?.string ?? turn.model
                    Self.apply(event["message"]?["usage"], to: &turn.usage)
                case "content_block_start":
                    if let index, case .object(let block)? = event["content_block"] { blocks[index] = block }
                case "content_block_delta":
                    guard let index, let delta = event["delta"] else { continue }
                    func append(_ key: String, _ more: String?) {
                        let existing = blocks[index]?[key]?.string ?? ""
                        blocks[index]?[key] = .string(existing + (more ?? ""))
                    }
                    switch delta["type"]?.string {
                    case "text_delta":
                        let text = delta["text"]?.string ?? ""
                        append("text", text)
                        await onText(await received.append(text))
                    case "thinking_delta":
                        append("thinking", delta["thinking"]?.string)
                    case "signature_delta":
                        append("signature", delta["signature"]?.string)
                    case "input_json_delta":
                        partialInputs[index, default: ""] += delta["partial_json"]?.string ?? ""
                    default:
                        break
                    }
                case "content_block_stop":
                    if let index, let partial = partialInputs.removeValue(forKey: index) {
                        // An empty input streams as nothing at all.
                        guard let input = partial.isEmpty ? JSONValue.object([:]) : JSONValue.parse(partial) else { throw CoachError.malformed }
                        blocks[index]?["input"] = input
                    }
                case "message_delta":
                    turn.stopReason = event["delta"]?["stop_reason"]?.string ?? turn.stopReason
                    Self.apply(event["usage"], to: &turn.usage)
                case "error":
                    throw Self.error(type: event["error"]?["type"]?.string, message: event["error"]?["message"]?.string ?? "", status: 0)
                default:
                    break
                }
            }
        } catch let error as CoachError {
            throw error
        } catch {
            throw Self.map(error)
        }

        turn.content = blocks.keys.sorted().compactMap { blocks[$0].map(JSONValue.object) }
        switch turn.stopReason {
        case "refusal": throw CoachError.refused
        case "max_tokens": throw CoachError.truncated
        case nil: throw CoachError.malformed
        default: return turn
        }
    }

    private static func apply(_ usage: JSONValue?, to total: inout ClaudeUsage) {
        guard let usage else { return }
        func count(_ key: String) -> Int? { usage[key]?.number.map(Int.init) }
        if let output = count("output_tokens") { total.outputTokens = output }
        guard count("input_tokens") != nil || count("cache_read_input_tokens") != nil else { return }
        total.cacheReadTokens = count("cache_read_input_tokens") ?? total.cacheReadTokens
        total.cacheWriteTokens = count("cache_creation_input_tokens") ?? total.cacheWriteTokens
        total.inputTokens = (count("input_tokens") ?? 0) + total.cacheReadTokens + total.cacheWriteTokens
    }

    static func request(apiKey: String, model: String, system: String, user: String, schema: [String: Any], effort: String = CoachConfiguration.effort) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CoachError.missingAPIKey }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": CoachConfiguration.maxTokens,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
        ]
        var request = URLRequest(url: CoachConfiguration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(CoachConfiguration.apiVersion, forHTTPHeaderField: "anthropic-version")
        // If the model declines, let the API re-run the request on its recommended fallback.
        if CoachConfiguration.model(model)?.supportsFallback == true {
            body["fallbacks"] = "default"
            request.setValue(CoachConfiguration.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private actor Received {
        var text = ""
        var isEmpty: Bool { text.isEmpty }

        func append(_ more: String) -> String {
            text += more
            return text
        }
    }

    private func stream(_ request: URLRequest, received: Received, onText: @Sendable (String) async -> Void) async throws -> ClaudeMessage {
        let status: Int
        let lines: AsyncThrowingStream<String, Error>
        do {
            (status, lines) = try await transport.send(request)
        } catch {
            throw Self.map(error)
        }

        guard status == 200 else {
            var body = ""
            for try await line in lines { body += line }
            throw Self.error(status: status, body: body)
        }

        var message = ClaudeMessage(text: "", model: "", stopReason: nil, usage: ClaudeUsage())
        do {
            for try await line in lines {
                guard line.hasPrefix("data:") else { continue }
                let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                guard let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }
                switch event.type {
                case "message_start":
                    message.model = event.message?.model ?? message.model
                    message.usage.inputTokens = event.message?.usage?.totalInput ?? 0
                    message.usage.outputTokens = event.message?.usage?.output_tokens ?? 0
                case "content_block_delta":
                    if event.delta?.type == "text_delta", let text = event.delta?.text {
                        await onText(await received.append(text))
                    }
                case "message_delta":
                    message.stopReason = event.delta?.stop_reason ?? message.stopReason
                    if let output = event.usage?.output_tokens { message.usage.outputTokens = output }
                    if let input = event.usage?.totalInput, input > 0 { message.usage.inputTokens = input }
                case "error":
                    throw Self.error(type: event.error?.type, message: event.error?.message ?? "", status: 0)
                default:
                    break
                }
            }
        } catch let error as CoachError {
            throw error
        } catch {
            throw Self.map(error)
        }

        message.text = await received.text
        switch message.stopReason {
        case "refusal": throw CoachError.refused
        case "max_tokens": throw CoachError.truncated
        default: return message
        }
    }

    // MARK: Errors

    private static func map(_ error: Error) -> CoachError {
        guard let urlError = error as? URLError else { return .offline }
        switch urlError.code {
        case .timedOut: return .timedOut
        default: return .offline
        }
    }

    private static func error(status: Int, body: String) -> CoachError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(body.utf8))
        return error(type: envelope?.error.type, message: envelope?.error.message ?? "", status: status)
    }

    private static func error(type: String?, message: String, status: Int) -> CoachError {
        switch (status, type) {
        case (401, _), (403, _), (_, "authentication_error"), (_, "permission_error"): .unauthorized
        case (429, _), (_, "rate_limit_error"): .rateLimited
        case (529, _), (_, "overloaded_error"): .overloaded
        default: .api(status: status, message: message)
        }
    }

    // MARK: Wire types

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            var type: String?
            var message: String?
        }

        var error: Detail
    }

    private struct StreamEvent: Decodable {
        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_read_input_tokens: Int?
            var cache_creation_input_tokens: Int?

            var totalInput: Int {
                (input_tokens ?? 0) + (cache_read_input_tokens ?? 0) + (cache_creation_input_tokens ?? 0)
            }
        }

        struct Message: Decodable {
            var model: String?
            var usage: Usage?
        }

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stop_reason: String?
        }

        var type: String
        var message: Message?
        var delta: Delta?
        var usage: Usage?
        var error: ErrorEnvelope.Detail?
    }
}
