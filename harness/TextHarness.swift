import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public typealias BeanBaoBridgeRequest = @Sendable (PHKJSONValue) -> PHKJSONValue

public struct BeanBaoTextResult: Sendable, Equatable {
    public let succeeded: Bool
    public let message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

private extension PHKJSONValue {
    var object: [String: PHKJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

private func encode(_ value: PHKJSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{\"ok\":false}" }
    return String(decoding: data, as: UTF8.self)
}

private func errorResult(_ message: String) -> PHKJSONValue {
    .object(["ok": .bool(false), "error": .string(message)])
}

private struct OpenAppTool: PHKNativeTool {
    let expectedBundle: String
    let bridge: BeanBaoBridgeRequest

    var definition: PHKToolDefinition {
        .init(name: "open_app", description: "Open the exact approved iPhone app and verify it is foreground.",
               parameters: .object([
                "type": .string("object"),
                "properties": .object(["bundle_id": .object(["type": .string("string")])]),
                "required": .array([.string("bundle_id")]),
                "additionalProperties": .bool(false)
               ]))
    }

    func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard let fields = arguments.object, fields.count == 1,
              fields["bundle_id"]?.string == expectedBundle else {
            return errorResult("App is outside this task's allowlist.")
        }
        if Task.isCancelled { return errorResult("Task cancelled.") }
        let lease = bridge(.object(["op": .string("wake_lease"), "mode": .string("renew")]))
        guard lease.object?["ok"]?.bool == true else { return errorResult("Screen wake lease unavailable.") }
        defer { _ = bridge(.object(["op": .string("wake_lease"), "mode": .string("release")])) }

        let initial = bridge(.object(["op": .string("observe")]))
        guard Self.unlocked(initial) else { return errorResult("Device is locked or screen is off.") }
        if Self.foreground(initial) == expectedBundle {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return errorResult("Task cancelled.") }
            let confirmed = bridge(.object(["op": .string("observe")]))
            guard Self.unlocked(confirmed), Self.foreground(confirmed) == expectedBundle else {
                return errorResult("Foreground app changed during verification.")
            }
            return .object(["ok": .bool(true)])
        }
        if Task.isCancelled { return errorResult("Task cancelled.") }

        // Refresh immediately before acting. The Bridge rejects a stale ID or
        // a foreground switch even if this client is interrupted afterward.
        let fresh = bridge(.object(["op": .string("observe")]))
        guard Self.unlocked(fresh),
              Self.foreground(fresh) == Self.foreground(initial),
              let id = fresh.object?["observation_id"]?.string,
              let timestamp = fresh.object?["timestamp"]?.number,
              (0...8).contains(Date().timeIntervalSince1970 - timestamp) else {
            return errorResult("Device state changed before opening the app.")
        }
        if Task.isCancelled { return errorResult("Task cancelled.") }
        let action = bridge(.object([
            "op": .string("act"), "action": .string("launch_app"),
            "bundle_id": .string(expectedBundle), "observation_id": .string(id)
        ]))
        guard action.object?["ok"]?.bool == true else { return errorResult("App launch was rejected.") }

        for attempt in 0..<5 {
            if Task.isCancelled { return errorResult("Task cancelled.") }
            let observed = bridge(.object(["op": .string("observe")]))
            guard Self.unlocked(observed) else { return errorResult("Device locked during app launch.") }
            if Self.foreground(observed) == expectedBundle {
                return .object(["ok": .bool(true)])
            }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(250)) }
        }
        return errorResult("App launch could not be verified.")
    }

    private static func unlocked(_ value: PHKJSONValue) -> Bool {
        guard value.object?["ok"]?.bool == true,
              let state = value.object?["device_state"]?.object else { return false }
        return state["locked_known"]?.bool == true && state["locked"]?.bool == false &&
            state["screen_on_known"]?.bool == true && state["screen_on"]?.bool == true
    }

    private static func foreground(_ value: PHKJSONValue) -> String? {
        value.object?["frontmost_app"]?.object?["bundleId"]?.string
    }
}

private struct FixedOpenAppModel: PHKModelClient {
    let bundle: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let events: [PHKModelEvent]
        if request.messages.last?.role == .tool {
            events = [.contentDelta("打开 App 操作已返回"), .completed(.stop)]
        } else {
            let arguments = encode(.object(["bundle_id": .string(bundle)]))
            events = [.toolCallDelta(.init(index: 0, id: UUID().uuidString,
                                            name: "open_app", arguments: arguments)),
                      .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

public enum BeanBaoTextHarness {
    public static let targets: [String: String] = [
        "打开设置": "com.apple.Preferences",
        "打开备忘录": "com.apple.mobilenotes",
        "打开地图": "com.apple.Maps",
        "打开通讯录": "com.apple.MobileAddressBook"
    ]

    public static func run(_ task: String, bridge: @escaping BeanBaoBridgeRequest) async -> BeanBaoTextResult {
        guard let bundle = targets[task] else {
            return .init(succeeded: false, message: "不支持的文字指令")
        }
        return await run(task, bridge: bridge, client: FixedOpenAppModel(bundle: bundle))
    }

    static func run(_ task: String, bridge: @escaping BeanBaoBridgeRequest,
                    client: any PHKModelClient) async -> BeanBaoTextResult {
        guard let bundle = targets[task] else {
            return .init(succeeded: false, message: "不支持的文字指令")
        }
        let agent = PHKAgentRuntime(client: client, model: "fixed-open-app",
                                    toolRegistry: PHKToolRegistry([OpenAppTool(expectedBundle: bundle, bridge: bridge)]),
                                    executionBudget: .init(maximumSteps: 3, maximumToolCalls: 1,
                                                           maximumDuration: .seconds(30)))
        do {
            let snapshot = try await agent.send(task)
            guard let toolMessage = snapshot.messages.last(where: { $0.role == .tool }),
                  let content = toolMessage.content,
                  let result = try? JSONDecoder().decode(PHKJSONValue.self, from: Data(content.utf8)),
                  result.object?["ok"]?.bool == true,
                  result.object?["result"]?.object?["ok"]?.bool == true else {
                return .init(succeeded: false, message: "打开 App 未完成")
            }
            return .init(succeeded: true, message: "目标 App 已在前台")
        } catch {
            return .init(succeeded: false, message: "文字任务执行失败")
        }
    }
}

#if os(iOS)
@_silgen_name("BBBridgeRequestJSON") private func BBBridgeRequestJSON(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("BBBridgeFreeJSON") private func BBBridgeFreeJSON(_ response: UnsafeMutablePointer<CChar>)
@_silgen_name("BBReleaseWakeLease") private func BBReleaseWakeLeaseForText()

private final class TextResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = BeanBaoTextResult(succeeded: false, message: "文字任务执行失败")
    func set(_ value: BeanBaoTextResult) { lock.lock(); result = value; lock.unlock() }
    func get() -> BeanBaoTextResult { lock.lock(); defer { lock.unlock() }; return result }
}

@_cdecl("BBRunHarnessText")
public func BBRunHarnessText(_ taskPointer: UnsafePointer<CChar>?) -> Int32 {
    guard let taskPointer else { return 2 }
    let task = String(cString: taskPointer)
    let bridge: BeanBaoBridgeRequest = { request in
        let payload = encode(request)
        return payload.withCString { pointer in
            guard let reply = BBBridgeRequestJSON(pointer) else { return .object(["ok": .bool(false)]) }
            defer { BBBridgeFreeJSON(reply) }
            return (try? JSONDecoder().decode(PHKJSONValue.self, from: Data(String(cString: reply).utf8))) ??
                .object(["ok": .bool(false)])
        }
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = TextResultBox()
    Task.detached {
        box.set(await BeanBaoTextHarness.run(task, bridge: bridge))
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + .seconds(45)) == .success else {
        BBReleaseWakeLeaseForText()
        fputs("文字任务超时\n", stderr)
        return 1
    }
    BBReleaseWakeLeaseForText()
    let result = box.get()
    let stream = result.succeeded ? stdout : stderr
    fputs(result.message + "\n", stream)
    return result.succeeded ? 0 : 1
}
#endif
