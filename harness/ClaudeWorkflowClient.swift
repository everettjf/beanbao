import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public enum BeanBaoClaudeError: Error, LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case incompleteResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The Claude workflow request is invalid."
        case .invalidResponse: "Claude returned an invalid workflow response."
        case .httpStatus(let status): "Claude returned HTTP \(status)."
        case .incompleteResponse: "Claude did not complete the workflow step."
        }
    }
}

public typealias BeanBaoClaudeTransport = @Sendable (URLRequest) async throws -> (Data, Int)

private final class BeanBaoNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct BeanBaoClaudeWorkflowClient: PHKModelClient {
    private let apiKey: String
    private let transport: BeanBaoClaudeTransport

    public init(apiKey: String, transport: BeanBaoClaudeTransport? = nil) {
        self.apiKey = apiKey
        self.transport = transport ?? Self.defaultTransport
    }

    public func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let payload = try Self.makeRequest(request, apiKey: apiKey)
                    let (data, status) = try await transport(payload)
                    guard status == 200 else { throw BeanBaoClaudeError.httpStatus(status) }
                    let events = try Self.parseResponse(data)
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func makeRequest(_ request: PHKCompletionRequest,
                                   apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace }),
              !request.model.isEmpty else { throw BeanBaoClaudeError.invalidRequest }
        var system: [String] = []
        var messages: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system:
                if let content = message.content, !content.isEmpty { system.append(content) }
            case .user:
                guard let content = message.content else { throw BeanBaoClaudeError.invalidRequest }
                messages.append(["role": "user", "content": [["type": "text", "text": content]]])
            case .assistant:
                var parts: [[String: Any]] = []
                if let content = message.content, !content.isEmpty {
                    parts.append(["type": "text", "text": content])
                }
                for call in message.toolCalls {
                    guard let input = try? decodeJSONObject(call.arguments) else {
                        throw BeanBaoClaudeError.invalidRequest
                    }
                    parts.append(["type": "tool_use", "id": call.id,
                                  "name": call.name, "input": input])
                }
                guard !parts.isEmpty else { throw BeanBaoClaudeError.invalidRequest }
                messages.append(["role": "assistant", "content": parts])
            case .tool:
                guard let id = message.toolCallID, !id.isEmpty,
                      let content = message.content else { throw BeanBaoClaudeError.invalidRequest }
                let error = message.blocks.contains { block in
                    if case .toolResult(_, _, let isError) = block { return isError }
                    return false
                }
                let result: [String: Any] = ["type": "tool_result", "tool_use_id": id,
                                             "content": content, "is_error": error]
                if let last = messages.indices.last,
                   messages[last]["role"] as? String == "user",
                   (messages[last]["content"] as? [[String: Any]])?.first?["type"] as? String == "tool_result" {
                    var previous = messages[last]["content"] as! [[String: Any]]
                    previous.append(result)
                    messages[last]["content"] = previous
                } else {
                    messages.append(["role": "user", "content": [result]])
                }
            }
        }
        guard !messages.isEmpty else { throw BeanBaoClaudeError.invalidRequest }
        let tools: [[String: Any]] = try request.tools.map { tool in
            let schema = try jsonObject(tool.parameters)
            return ["name": tool.name, "description": tool.description,
                    "input_schema": schema]
        }
        var body: [String: Any] = ["model": request.model, "max_tokens": 4096,
                                   "messages": messages]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if !tools.isEmpty { body["tools"] = tools }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        guard encoded.count <= 512 * 1024,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw BeanBaoClaudeError.invalidRequest
        }
        var output = URLRequest(url: url)
        output.httpMethod = "POST"
        output.httpBody = encoded
        output.timeoutInterval = 90
        output.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        output.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        output.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return output
    }

    public static func parseResponse(_ data: Data) throws -> [PHKModelEvent] {
        guard data.count <= 2 * 1024 * 1024,
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = response["stop_reason"] as? String,
              let content = response["content"] as? [[String: Any]] else {
            throw BeanBaoClaudeError.invalidResponse
        }
        guard reason == "tool_use" || reason == "end_turn" || reason == "stop_sequence" else {
            throw BeanBaoClaudeError.incompleteResponse
        }
        var events: [PHKModelEvent] = []
        var toolCalls = 0
        for (index, block) in content.enumerated() {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String else {
                    throw BeanBaoClaudeError.invalidResponse
                }
                events.append(.contentDelta(text))
            case "tool_use":
                guard let id = block["id"] as? String, !id.isEmpty,
                      let name = block["name"] as? String, !name.isEmpty,
                      let input = block["input"] as? [String: Any] else {
                    throw BeanBaoClaudeError.invalidResponse
                }
                let arguments = try JSONSerialization.data(withJSONObject: input,
                                                           options: [.sortedKeys])
                events.append(.toolCallDelta(.init(index: index, id: id, name: name,
                                                   arguments: String(decoding: arguments, as: UTF8.self))))
                toolCalls += 1
            default:
                // Server-side search/fetch blocks stay out of the local tool
                // registry. Research tools handle and cite them separately.
                continue
            }
        }
        guard (reason == "tool_use") == (toolCalls > 0) else {
            throw BeanBaoClaudeError.invalidResponse
        }
        if let usage = response["usage"] as? [String: Any],
           let input = usage["input_tokens"] as? Int,
           let output = usage["output_tokens"] as? Int {
            events.append(.usage(.init(promptTokens: input, completionTokens: output,
                                        totalTokens: input + output)))
        }
        events.append(.completed(reason == "tool_use" ? .toolCalls : .stop))
        return events
    }

    private static func jsonObject(_ value: PHKJSONValue) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BeanBaoClaudeError.invalidRequest
        }
        return object
    }

    private static func decodeJSONObject(_ encoded: String) throws -> [String: Any] {
        guard let data = encoded.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BeanBaoClaudeError.invalidRequest
        }
        return object
    }

    static func defaultTransport(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration,
                                 delegate: BeanBaoNoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BeanBaoClaudeError.invalidResponse
        }
        return (data, http.statusCode)
    }
}
