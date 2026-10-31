import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public typealias BeanBaoNoteStep = @Sendable (String, [PHKJSONValue]) -> PHKJSONValue

private extension PHKJSONValue {
    var noteObject: [String: PHKJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var noteBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

private func noteJSON(_ value: PHKJSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

private final class NoteStepTool: PHKNativeTool, @unchecked Sendable {
    let definition = PHKToolDefinition(
        name: "note_step", description: "Advance one bounded local Notes action and verify its UI state.",
        parameters: .object(["type": .string("object"), "properties": .object([:]),
                             "additionalProperties": .bool(false)]))
    private let task: String
    private let step: BeanBaoNoteStep
    private let lock = NSLock()
    private var history: [PHKJSONValue] = []

    init(task: String, step: @escaping BeanBaoNoteStep) {
        self.task = task
        self.step = step
    }

    func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard arguments.noteObject?.isEmpty == true, !Task.isCancelled else {
            return .object(["ok": .bool(false), "done": .bool(false)])
        }
        let previous = lock.withLock { history }
        let response = step(task, previous)
        guard response.noteObject?["ok"]?.noteBool == true else {
            return .object(["ok": .bool(false), "done": .bool(false)])
        }
        let done = response.noteObject?["done"]?.noteBool == true
        if !done {
            guard let action = response.noteObject?["action"],
                  action.noteObject != nil else {
                return .object(["ok": .bool(false), "done": .bool(false)])
            }
            lock.withLock { history.append(action) }
        }
        // The tool result omits note text, AX data, and coordinates.
        return .object(["ok": .bool(true), "done": .bool(done)])
    }
}

private struct FixedNoteModel: PHKModelClient {
    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let events: [PHKModelEvent]
        if let last = request.messages.last, last.role == .tool {
            let result = last.content.flatMap { try? JSONDecoder().decode(PHKJSONValue.self, from: Data($0.utf8)) }
            let envelope = result?.noteObject
            let step = envelope?["result"]?.noteObject
            if envelope?["ok"]?.noteBool != true || step?["ok"]?.noteBool != true ||
                step?["done"]?.noteBool == true {
                events = [.completed(.stop)]
            } else {
                events = Self.nextStep()
            }
        } else {
            events = Self.nextStep()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private static func nextStep() -> [PHKModelEvent] {
        [.toolCallDelta(.init(index: 0, id: UUID().uuidString,
                              name: "note_step", arguments: "{}")),
         .completed(.toolCalls)]
    }
}

public enum BeanBaoNoteHarness {
    public static func run(_ task: String, step: @escaping BeanBaoNoteStep) async -> BeanBaoTextResult {
        guard task.hasPrefix("新建备忘录："), task.utf16.count >= 10, task.utf16.count <= 166,
              task.rangeOfCharacter(from: .newlines) == nil else {
            return .init(succeeded: false, message: "无效的备忘录文字指令")
        }
        let agent = PHKAgentRuntime(
            client: FixedNoteModel(), model: "fixed-note",
            toolRegistry: PHKToolRegistry([NoteStepTool(task: task, step: step)]),
            executionBudget: .init(maximumSteps: 12, maximumToolCalls: 10,
                                   maximumRepeatedToolCalls: 10, maximumDuration: .seconds(300)))
        do {
            let snapshot = try await agent.send(task)
            guard let last = snapshot.messages.last(where: { $0.role == .tool }),
                  let content = last.content,
                  let result = try? JSONDecoder().decode(PHKJSONValue.self, from: Data(content.utf8)),
                  result.noteObject?["ok"]?.noteBool == true,
                  result.noteObject?["result"]?.noteObject?["ok"]?.noteBool == true,
                  result.noteObject?["result"]?.noteObject?["done"]?.noteBool == true else {
                return .init(succeeded: false, message: "备忘录界面状态不符合安全条件")
            }
            return .init(succeeded: true, message: "备忘录已创建")
        } catch {
            return .init(succeeded: false, message: "备忘录界面状态不符合安全条件")
        }
    }
}

#if os(iOS)
@_silgen_name("BBNoteStepJSON") private func BBNoteStepJSON(
    _ task: UnsafePointer<CChar>, _ history: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("BBBridgeFreeJSON") private func BBNoteFreeJSON(_ response: UnsafeMutablePointer<CChar>)
@_silgen_name("BBReleaseWakeLease") private func BBReleaseWakeLease()

private final class NoteResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = BeanBaoTextResult(succeeded: false, message: "备忘录界面状态不符合安全条件")
    func set(_ value: BeanBaoTextResult) { lock.lock(); result = value; lock.unlock() }
    func get() -> BeanBaoTextResult { lock.lock(); defer { lock.unlock() }; return result }
}

@_cdecl("BBRunHarnessNote")
public func BBRunHarnessNote(_ taskPointer: UnsafePointer<CChar>?) -> Int32 {
    guard let taskPointer else { return 2 }
    let task = String(cString: taskPointer)
    let step: BeanBaoNoteStep = { command, history in
        let historyJSON = noteJSON(.array(history))
        return command.withCString { taskCString in
            historyJSON.withCString { historyCString in
                guard let reply = BBNoteStepJSON(taskCString, historyCString) else {
                    return .object(["ok": .bool(false)])
                }
                defer { BBNoteFreeJSON(reply) }
                return (try? JSONDecoder().decode(PHKJSONValue.self,
                           from: Data(String(cString: reply).utf8))) ?? .object(["ok": .bool(false)])
            }
        }
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = NoteResultBox()
    Task.detached {
        box.set(await BeanBaoNoteHarness.run(task, step: step))
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + .seconds(330)) == .success else {
        BBReleaseWakeLease()
        fputs("备忘录界面状态不符合安全条件\n", stderr)
        return 1
    }
    BBReleaseWakeLease()
    let result = box.get()
    fputs(result.message + "\n", result.succeeded ? stdout : stderr)
    return result.succeeded ? 0 : 1
}
#endif
