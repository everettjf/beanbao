import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private actor ClaudeToolCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

final class ClaudeWorkflowClientTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testRequestEncodesToolCallsAndPairedResults() throws {
        let definition = PHKToolDefinition(
            name: "find_sources", description: "Find cited sources",
            parameters: .object(["type": .string("object"), "properties": .object([:])]))
        let messages: [PHKChatMessage] = [
            .init(role: .system, content: "Use only available tools"),
            .init(role: .user, content: "Research iOS speech recognition"),
            .init(role: .assistant, content: "I will search", toolCalls: [
                .init(id: "call-1", name: "find_sources", arguments: "{}")
            ]),
            .init(role: .tool, content: "{\"ok\":true}", toolCallID: "call-1")
        ]
        let request = try BeanBaoClaudeWorkflowClient.makeRequest(
            .init(model: "claude-test", messages: messages, tools: [definition]),
            apiKey: "placeholder-key")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "Use only available tools")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "find_sources")
        let history = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(history.count, 3)
        let assistant = try XCTUnwrap(history[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.last?["id"] as? String, "call-1")
        let result = try XCTUnwrap(history[2]["content"] as? [[String: Any]])
        XCTAssertEqual(result.first?["tool_use_id"] as? String, "call-1")
    }

    func testResponseParsesTextToolCallAndUsage() throws {
        let response = try json([
            "stop_reason": "tool_use",
            "content": [["type": "text", "text": "Searching"],
                        ["type": "tool_use", "id": "call-1", "name": "find_sources",
                         "input": ["query": "iOS Speech"]]],
            "usage": ["input_tokens": 11, "output_tokens": 7]
        ])
        let events = try BeanBaoClaudeWorkflowClient.parseResponse(response)
        XCTAssertEqual(events.first, .contentDelta("Searching"))
        let call = events.compactMap { event -> PHKToolCallDelta? in
            if case .toolCallDelta(let value) = event { return value }
            return nil
        }.first
        XCTAssertEqual(call?.name, "find_sources")
        XCTAssertEqual(call?.id, "call-1")
        XCTAssertEqual(events.last, .completed(.toolCalls))
        XCTAssertTrue(events.contains(.usage(.init(promptTokens: 11,
                                                   completionTokens: 7, totalTokens: 18))))
    }

    func testIncompleteOrContradictoryResponseCannotExecuteTool() throws {
        let refused = try json(["stop_reason": "refusal", "content": []])
        XCTAssertThrowsError(try BeanBaoClaudeWorkflowClient.parseResponse(refused))
        let truncated = try json(["stop_reason": "max_tokens", "content": [
            ["type": "tool_use", "id": "call-1", "name": "send_mail", "input": [:]]
        ]])
        XCTAssertThrowsError(try BeanBaoClaudeWorkflowClient.parseResponse(truncated))
        let mismatched = try json(["stop_reason": "end_turn", "content": [
            ["type": "tool_use", "id": "call-1", "name": "send_mail", "input": [:]]
        ]])
        XCTAssertThrowsError(try BeanBaoClaudeWorkflowClient.parseResponse(mismatched))
    }

    func testClaudeTransportDrivesPalminoToolLoopOffline() async throws {
        let counter = ClaudeToolCounter()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-claude-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try BeanBaoWorkflowStore(url: parent.appendingPathComponent("session.json"),
                                             request: "Find sources")
        let client = BeanBaoClaudeWorkflowClient(apiKey: "placeholder-key") { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let hasResult = messages.contains { message in
                ((message["content"] as? [[String: Any]]) ?? []).contains {
                    $0["type"] as? String == "tool_result"
                }
            }
            let response: [String: Any] = hasResult ? [
                "stop_reason": "end_turn", "content": [["type": "text", "text": "Done"]]
            ] : [
                "stop_reason": "tool_use", "content": [
                    ["type": "tool_use", "id": "call-1", "name": "find_sources", "input": [:]]
                ]
            ]
            return (try JSONSerialization.data(withJSONObject: response), 200)
        }
        let tool = BeanBaoGuardedWorkflowTool(
            definition: .init(name: "find_sources", description: "Find sources",
                              parameters: .object(["type": .string("object"),
                                                   "properties": .object([:]),
                                                   "additionalProperties": .bool(false)])),
            effect: .readOnly, store: store) { _ in
                await counter.increment()
                return .object(["url": .string("https://example.org")])
            }
        let session = await BeanBaoWorkflowSession(
            store: store, client: client, model: "claude-test", systemPrompt: "Find sources",
            tools: [tool], completionCheck: { await counter.value() == 1 })
        let output = try await session.run("Find sources")
        XCTAssertEqual(output.phase, .completed)
        let calls = await counter.value()
        XCTAssertEqual(calls, 1)
    }
}
