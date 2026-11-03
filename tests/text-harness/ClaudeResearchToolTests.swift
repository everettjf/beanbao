import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private actor ResearchRequestLog {
    private var bodies: [Data] = []
    func append(_ value: Data) { bodies.append(value) }
    func count() -> Int { bodies.count }
    func lastToolType() -> String? {
        guard let data = bodies.last,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = body["tools"] as? [[String: Any]] else { return nil }
        return tools.first?["type"] as? String
    }
    func lastRole() -> String? {
        guard let data = bodies.last,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]] else { return nil }
        return messages.last?["role"] as? String
    }
}

final class ClaudeResearchToolTests: XCTestCase {
    private func sampleResponse() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [
                ["type": "server_tool_use", "id": "srv-1", "name": "web_search", "input": ["query": "iOS speech"]],
                ["type": "web_search_tool_result", "tool_use_id": "srv-1", "content": [
                    ["type": "web_search_result", "url": "https://developer.apple.com/documentation/speech",
                     "title": "Speech", "encrypted_content": "opaque"]
                ]],
                ["type": "text", "text": "Apple provides speech recognition APIs.", "citations": [
                    ["type": "web_search_result_location",
                     "url": "https://developer.apple.com/documentation/speech",
                     "title": "Speech | Apple Developer",
                     "cited_text": "Recognize and transcribe speech"]
                ]]
            ]
        ])
    }

    func testSearchReturnsOnlyCitedSourcesAndRecordsEvidence() async throws {
        let response = try sampleResponse()
        let log = ResearchRequestLog()
        let client = BeanBaoClaudeWebSearch(model: "claude-test", apiKey: "placeholder") { request in
            await log.append(try XCTUnwrap(request.httpBody))
            return (response, 200)
        }
        let evidence = BeanBaoResearchEvidence()
        let tool = BeanBaoWebSearchTool(client: client, evidence: evidence)
        let result = try await tool.execute(arguments: .object(["query": .string("iOS speech APIs")]))
        guard case .object(let fields) = result,
              case .array(let sources)? = fields["sources"] else {
            XCTFail("Expected cited source result")
            return
        }
        XCTAssertEqual(sources.count, 1)
        let known = await evidence.contains("https://developer.apple.com/documentation/speech")
        XCTAssertTrue(known)
        let type = await log.lastToolType()
        XCTAssertEqual(type, "web_search_20250305")
    }

    func testPauseTurnPreservesServerBlocksWhenContinuing() async throws {
        let response = try sampleResponse()
        let paused = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "pause_turn", "content": [
                ["type": "server_tool_use", "id": "srv-1", "name": "web_search",
                 "input": ["query": "iOS speech"]]
            ]
        ])
        let log = ResearchRequestLog()
        let client = BeanBaoClaudeWebSearch(model: "claude-test", apiKey: "placeholder") { request in
            await log.append(try XCTUnwrap(request.httpBody))
            let count = await log.count()
            return (count == 1 ? paused : response, 200)
        }
        let result = try await client.search("iOS speech APIs")
        XCTAssertEqual(result.sources.count, 1)
        let count = await log.count()
        XCTAssertEqual(count, 2)
        let role = await log.lastRole()
        XCTAssertEqual(role, "assistant")
    }

    func testUncitedAnswerIsRejected() throws {
        let content: [[String: Any]] = [
            ["type": "web_search_tool_result", "content": []],
            ["type": "text", "text": "Unsupported claim"]
        ]
        XCTAssertThrowsError(try BeanBaoClaudeWebSearch.parseFinding(content))
    }

    func testCitationWithoutQuotedEvidenceIsRejected() throws {
        let url = "https://developer.apple.com/documentation/speech"
        let content: [[String: Any]] = [
            ["type": "web_search_tool_result", "content": [[
                "type": "web_search_result", "url": url, "title": "Speech"]]],
            ["type": "text", "text": "Apple documents speech APIs.",
             "citations": [["type": "web_search_result_location", "url": url,
                             "title": "Speech", "cited_text": "  "]]]
        ]
        XCTAssertThrowsError(try BeanBaoClaudeWebSearch.parseFinding(content))
    }
}
