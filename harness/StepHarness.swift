import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public typealias BeanBaoDeviceStep = @Sendable (String, [PHKJSONValue]) -> PHKJSONValue

private extension PHKJSONValue {
    var stepObject: [String: PHKJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var stepBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    var stepString: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

private final class DeviceStepTool: PHKNativeTool, @unchecked Sendable {
    let definition: PHKToolDefinition
    private let task: String
    private let step: BeanBaoDeviceStep
    private let lock = NSLock()
    private var history: [PHKJSONValue] = []

    init(name: String, task: String, step: @escaping BeanBaoDeviceStep) {
        definition = .init(name: name, description: "Advance one approved iPhone UI action and verify its state.",
                           parameters: .object(["type": .string("object"), "properties": .object([:]),
                                                "additionalProperties": .bool(false)]))
        self.task = task
        self.step = step
    }

    func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard arguments.stepObject?.isEmpty == true, !Task.isCancelled else {
            return .object(["ok": .bool(false), "done": .bool(false), "error": .string("invalid_arguments")])
        }
        let previous = lock.withLock { history }
        let response = step(task, previous)
        guard let fields = response.stepObject, fields["ok"]?.stepBool == true else {
            let code = response.stepObject?["error"]?.stepString ?? "step_failed"
            return .object(["ok": .bool(false), "done": .bool(false), "error": .string(code)])
        }
        let done = fields["done"]?.stepBool == true
        if !done {
            guard let action = fields["action"], action.stepObject != nil else {
                return .object(["ok": .bool(false), "done": .bool(false), "error": .string("invalid_action")])
            }
            lock.withLock { history.append(action) }
        }
        // Only fixed status fields enter the model transcript. History stays in this process.
        return .object(["ok": .bool(true), "done": .bool(done)])
    }
}

private struct FixedStepModel: PHKModelClient {
    let toolName: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let events: [PHKModelEvent]
        if let last = request.messages.last, last.role == .tool {
            let result = last.content.flatMap { try? JSONDecoder().decode(PHKJSONValue.self, from: Data($0.utf8)) }
            let envelope = result?.stepObject
            let step = envelope?["result"]?.stepObject
            if envelope?["ok"]?.stepBool != true || step?["ok"]?.stepBool != true ||
                step?["done"]?.stepBool == true {
                events = [.completed(.stop)]
            } else {
                events = nextStep()
            }
        } else {
            events = nextStep()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private func nextStep() -> [PHKModelEvent] {
        [.toolCallDelta(.init(index: 0, id: UUID().uuidString,
                              name: toolName, arguments: "{}")),
         .completed(.toolCalls)]
    }
}

public enum BeanBaoStepHarness {
    public static func run(_ task: String, toolName: String,
                           maximumToolCalls: Int, maximumDuration: Duration,
                           successMessage: String, failureMessage: String,
                           failureMessages: [String: String] = [:],
                           step: @escaping BeanBaoDeviceStep) async -> BeanBaoTextResult {
        let agent = PHKAgentRuntime(
            client: FixedStepModel(toolName: toolName), model: "fixed-\(toolName)",
            toolRegistry: PHKToolRegistry([DeviceStepTool(name: toolName, task: task, step: step)]),
            executionBudget: .init(maximumSteps: maximumToolCalls + 2,
                                   maximumToolCalls: maximumToolCalls,
                                   maximumRepeatedToolCalls: maximumToolCalls,
                                   maximumToolDuration: .seconds(90),
                                   maximumDuration: maximumDuration))
        do {
            let snapshot = try await agent.send(task)
            guard let last = snapshot.messages.last(where: { $0.role == .tool }),
                  let content = last.content,
                  let result = try? JSONDecoder().decode(PHKJSONValue.self, from: Data(content.utf8)) else {
                return .init(succeeded: false, message: failureMessage)
            }
            let envelope = result.stepObject
            let device = envelope?["result"]?.stepObject
            if envelope?["ok"]?.stepBool == true && device?["ok"]?.stepBool == true &&
                device?["done"]?.stepBool == true {
                return .init(succeeded: true, message: successMessage)
            }
            let code = device?["error"]?.stepString
            return .init(succeeded: false, message: code.flatMap { failureMessages[$0] } ?? failureMessage)
        } catch {
            return .init(succeeded: false, message: failureMessage)
        }
    }
}
