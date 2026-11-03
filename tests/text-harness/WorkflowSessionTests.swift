import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private actor WorkflowCallCounter {
    private var count = 0
    func increment() -> Int { count += 1; return count }
    func value() -> Int { count }
}

private struct TwoStepModel: PHKModelClient {
    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let completed = request.messages.filter { $0.role == .tool }.count
        let events: [PHKModelEvent]
        if completed >= 2 {
            events = [.contentDelta("Complete"), .completed(.stop)]
        } else {
            let name = completed == 0 ? "find_sources" : "render_report"
            events = [
                .toolCallDelta(.init(index: 0, id: "call-\(completed)", name: name, arguments: "{}")),
                .completed(.toolCalls)
            ]
        }
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private struct ValidationRetryModel: PHKModelClient {
    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let completed = request.messages.filter { $0.role == .tool }.count
        return AsyncThrowingStream { continuation in
            if completed >= 2 {
                continuation.yield(.contentDelta("Report ready"))
                continuation.yield(.completed(.stop))
            } else {
                let argument = completed == 0 ? "false" : "true"
                continuation.yield(.toolCallDelta(.init(index: 0,
                    id: "compose-\(completed)", name: "report_compose",
                    arguments: "{\"valid\":\(argument)}")))
                continuation.yield(.completed(.toolCalls))
            }
            continuation.finish()
        }
    }
}

final class WorkflowSessionTests: XCTestCase {
    private func location() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-workflow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent.appendingPathComponent("session.json")
    }

    private func definition(_ name: String) -> PHKToolDefinition {
        .init(name: name, description: name,
              parameters: .object(["type": .string("object"),
                                   "properties": .object([:]),
                                   "additionalProperties": .bool(false)]))
    }

    func testPalminoRunsTwoToolsAndPersistsTheirEvidence() async throws {
        let url = try location()
        let store = try BeanBaoWorkflowStore(url: url, request: "Research and render")
        let counter = WorkflowCallCounter()
        let search = BeanBaoGuardedWorkflowTool(definition: definition("find_sources"),
                                                effect: .readOnly, store: store) { _ in
            _ = await counter.increment()
            return .object(["source": .string("https://example.org/reference")])
        }
        let render = BeanBaoGuardedWorkflowTool(definition: definition("render_report"),
                                                effect: .localMutation, store: store) { _ in
            _ = await counter.increment()
            return .object(["pdf": .string("report.pdf")])
        }
        let session = await BeanBaoWorkflowSession(
            store: store, client: TwoStepModel(), model: "scripted",
            systemPrompt: "Use tools, then finish.", tools: [search, render],
            completionCheck: { await counter.value() == 2 })
        let output = try await session.run("Research and render")
        XCTAssertEqual(output.phase, .completed)
        let completedCalls = await counter.value()
        XCTAssertEqual(completedCalls, 2)
        let saved = await store.snapshot()
        XCTAssertEqual(saved.phase, .completed)
        XCTAssertEqual(saved.operations.count, 2)
        XCTAssertNotNil(saved.checkpoint)
        XCTAssertEqual(saved.checkpoint?.messages.filter { $0.role == .tool }.count, 2)

        let restored = try BeanBaoWorkflowStore(url: url, request: "Research and render")
        let reopened = await restored.snapshot()
        XCTAssertEqual(reopened.id, saved.id)
        XCTAssertEqual(reopened.operations.count, 2)
        XCTAssertEqual(reopened.checkpoint?.messages.count, saved.checkpoint?.messages.count)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCompletedMutationReturnsSavedResultWithoutRepeatingEffect() async throws {
        let store = try BeanBaoWorkflowStore(url: location(), request: "Create artifact")
        let counter = WorkflowCallCounter()
        let tool = BeanBaoGuardedWorkflowTool(definition: definition("render_report"),
                                              effect: .localMutation, store: store) { _ in
            let count = await counter.increment()
            return .number(Double(count))
        }
        let first = try await tool.execute(arguments: .object([:]))
        let second = try await tool.execute(arguments: .object([:]))
        XCTAssertEqual(first, second)
        let calls = await counter.value()
        XCTAssertEqual(calls, 1)
    }

    func testFailedMutationNeedsReconciliationAfterRestart() async throws {
        struct SimulatedFailure: Error {}
        let url = try location()
        let original = try BeanBaoWorkflowStore(url: url, request: "Submit order")
        let counter = WorkflowCallCounter()
        let failing = BeanBaoGuardedWorkflowTool(definition: definition("submit_order"),
                                                 effect: .localMutation, store: original) { _ in
            _ = await counter.increment()
            throw SimulatedFailure()
        }
        do {
            _ = try await failing.execute(arguments: .object([:]))
            XCTFail("The simulated failure should propagate")
        } catch is SimulatedFailure { }
        let state = await original.snapshot()
        XCTAssertEqual(state.phase, .needsReconciliation)

        let restored = try BeanBaoWorkflowStore(url: url, request: "Submit order")
        let retry = BeanBaoGuardedWorkflowTool(definition: definition("submit_order"),
                                               effect: .localMutation, store: restored) { _ in
            _ = await counter.increment()
            return .bool(true)
        }
        do {
            _ = try await retry.execute(arguments: .object([:]))
            XCTFail("An uncertain mutation must never repeat")
        } catch BeanBaoWorkflowError.outcomeUnconfirmed { }
        do {
            _ = try await retry.execute(arguments: .object(["different": .bool(true)]))
            XCTFail("A different argument must not bypass an uncertain mutation")
        } catch BeanBaoWorkflowError.outcomeUnconfirmed { }
        let calls = await counter.value()
        XCTAssertEqual(calls, 1)
        let session = await BeanBaoWorkflowSession(store: restored, client: TwoStepModel(),
            model: "scripted", systemPrompt: "Finish", tools: [retry],
            completionCheck: { true })
        do {
            _ = try await session.run("Submit order")
            XCTFail("A model's success response cannot complete an unresolved mutation")
        } catch BeanBaoWorkflowError.outcomeUnconfirmed { }
        let afterRun = await restored.snapshot()
        XCTAssertEqual(afterRun.phase, .needsReconciliation)
    }

    func testPreWriteValidationFailureCanBeCorrectedWithoutReconciliation() async throws {
        let store = try BeanBaoWorkflowStore(url: location(), request: "Compose report")
        let tool = BeanBaoGuardedWorkflowTool(definition: definition("report_compose"),
                                              effect: .localMutation, store: store) { args in
            guard case .object(let fields) = args, fields["valid"] == .bool(true) else {
                throw BeanBaoReportError.invalidStructure
            }
            return .bool(true)
        }
        do {
            _ = try await tool.execute(arguments: .object(["valid": .bool(false)]))
            XCTFail("Invalid structure must fail before writing")
        } catch BeanBaoReportError.invalidStructure { }
        let failed = await store.snapshot()
        XCTAssertEqual(failed.phase, .running)
        XCTAssertEqual(failed.operations.values.first?.state, .failed)
        _ = try await tool.execute(arguments: .object(["valid": .bool(true)]))
        try await store.assertSafeToComplete()
        let completed = await store.snapshot()
        XCTAssertFalse(completed.hasUnresolvedMutation)
        XCTAssertEqual(completed.operations.values.filter { $0.state == .completed }.count, 1)
    }

    func testPalminoRetriesInvalidReportArgumentsAndCompletesCleanly() async throws {
        let store = try BeanBaoWorkflowStore(url: location(), request: "Compose report")
        let counter = WorkflowCallCounter()
        let definition = PHKToolDefinition(name: "report_compose", description: "Compose report",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["valid": .object(["type": .string("boolean")])]),
                "required": .array([.string("valid")]),
                "additionalProperties": .bool(false)
            ]))
        let tool = BeanBaoGuardedWorkflowTool(definition: definition,
                                              effect: .localMutation, store: store) { args in
            guard case .object(let fields) = args, fields["valid"] == .bool(true) else {
                throw BeanBaoReportError.invalidStructure
            }
            _ = await counter.increment()
            return .bool(true)
        }
        let session = await BeanBaoWorkflowSession(store: store,
            client: ValidationRetryModel(), model: "scripted",
            systemPrompt: "Compose a report", tools: [tool],
            completionCheck: { await counter.value() == 1 })
        _ = try await session.run("Compose report")
        let saved = await store.snapshot()
        XCTAssertEqual(saved.phase, .completed)
        XCTAssertEqual(saved.operations.values.filter { $0.state == .failed }.count, 1)
        XCTAssertEqual(saved.operations.values.filter { $0.state == .completed }.count, 1)
        XCTAssertFalse(saved.hasUnresolvedMutation)
    }

    func testOldCompletedRecordWithUnresolvedMutationIsReconciledOnLoad() async throws {
        let url = try location()
        let store = try BeanBaoWorkflowStore(url: url, request: "Research and render")
        _ = try await store.claim(key: "uncertain-report", tool: "report_compose",
                                  effect: .localMutation)
        try await store.fail(key: "uncertain-report")
        try await store.setPhase(.completed)
        let inconsistent = await store.snapshot()
        XCTAssertEqual(inconsistent.phase, .completed)
        let restored = try BeanBaoWorkflowStore(existingURL: url)
        let repaired = await restored.snapshot()
        XCTAssertEqual(repaired.phase, .needsReconciliation)
        XCTAssertTrue(repaired.hasUnresolvedMutation)
        let persisted = try BeanBaoWorkflowStore(url: url, request: "Research and render")
        let saved = await persisted.snapshot()
        XCTAssertEqual(saved.phase, .needsReconciliation)
    }

    func testExternalCommitCannotRunWithoutFreshApproval() async throws {
        let store = try BeanBaoWorkflowStore(url: location(), request: "Send report")
        let counter = WorkflowCallCounter()
        let denied = BeanBaoGuardedWorkflowTool(definition: definition("send_mail"),
                                                effect: .externalCommit, store: store) { _ in
            _ = await counter.increment()
            return .bool(true)
        }
        do {
            _ = try await denied.execute(arguments: .object([:]))
            XCTFail("Send must require approval")
        } catch BeanBaoWorkflowError.approvalRequired { }
        let deniedCalls = await counter.value()
        XCTAssertEqual(deniedCalls, 0)

        let approved = BeanBaoGuardedWorkflowTool(definition: definition("send_mail"),
                                                  effect: .externalCommit, store: store,
                                                  approval: { _ in true }) { _ in
            _ = await counter.increment()
            return .bool(true)
        }
        _ = try await approved.execute(arguments: .object([:]))
        let approvedCalls = await counter.value()
        XCTAssertEqual(approvedCalls, 1)
    }

    func testModelStopWithoutVerifiedResultIsNotSuccess() async throws {
        let store = try BeanBaoWorkflowStore(url: location(), request: "Research and render")
        let search = BeanBaoGuardedWorkflowTool(definition: definition("find_sources"),
                                                effect: .readOnly, store: store) { _ in .bool(true) }
        let render = BeanBaoGuardedWorkflowTool(definition: definition("render_report"),
                                                effect: .localMutation, store: store) { _ in .bool(true) }
        let session = await BeanBaoWorkflowSession(
            store: store, client: TwoStepModel(), model: "scripted",
            systemPrompt: "Use tools, then finish.", tools: [search, render],
            completionCheck: { false })
        do {
            _ = try await session.run("Research and render")
            XCTFail("An unverified result must not complete")
        } catch BeanBaoWorkflowError.completionUnverified { }
        let state = await store.snapshot()
        XCTAssertEqual(state.phase, .failed)
    }
}
