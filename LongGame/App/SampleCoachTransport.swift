import Coach
import Foundation

/// Stands in for the Claude API in sample-data mode when no key is set, so the chat
/// screen can be exercised end to end in the simulator. It streams a canned reply at a
/// realistic pace and never touches the network.
struct SampleCoachTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let reply =
            "Sample reply, not written by the coach. This stands in for a real answer so sending, waiting and leaving the screen can be tried without an API key."
        func event(_ object: [String: Any]) -> String {
            "data: " + String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    continuation.yield(
                        event([
                            "type": "message_start",
                            "message": ["model": "sample", "usage": ["input_tokens": 0, "output_tokens": 0]],
                        ]))
                    // Long enough to leave the screen and come back while it is "thinking".
                    try await Task.sleep(for: .seconds(4))
                    continuation.yield(
                        event([
                            "type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""],
                        ]))
                    for word in reply.split(separator: " ") {
                        try await Task.sleep(for: .milliseconds(120))
                        continuation.yield(
                            event([
                                "type": "content_block_delta", "index": 0,
                                "delta": ["type": "text_delta", "text": word + " "],
                            ]))
                    }
                    continuation.yield(event(["type": "content_block_stop", "index": 0]))
                    continuation.yield(
                        event([
                            "type": "message_delta", "delta": ["stop_reason": "end_turn"],
                            "usage": ["output_tokens": 0],
                        ]))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (200, lines)
    }
}
