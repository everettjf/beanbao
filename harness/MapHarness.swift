import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public typealias BeanBaoMapStep = BeanBaoDeviceStep

private func mapJSON(_ value: PHKJSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

public enum BeanBaoMapHarness {
    public static func run(_ task: String, step: @escaping BeanBaoMapStep) async -> BeanBaoTextResult {
        guard task.hasPrefix("在地图搜索"), task.utf16.count > 5, task.utf16.count <= 55,
              task.rangeOfCharacter(from: .newlines) == nil else {
            return .init(succeeded: false, message: "Invalid Maps search request")
        }
        return await BeanBaoStepHarness.run(
            task, toolName: "map_step", maximumToolCalls: 20,
            maximumDuration: .seconds(300), successMessage: "Maps search completed",
            failureMessage: "Maps search incomplete. Check the screen.",
            failureMessages: [
                "key": "Model key is not configured or has unsafe permissions",
                "locked": "Device is locked or screen is off",
                "wake_lease": "Could not keep the screen awake",
                "sensitive": "The screen or request may contain sensitive information",
                "model": "Model request or response failed",
                "local_state": "Cannot safely use the current Maps screen",
                "input_unverified": "Could not verify the requested place in Maps",
                "policy": "Model action was rejected by policy",
                "fresh_state": "Screen verification failed"
            ], step: step)
    }
}

#if os(iOS)
@_silgen_name("BBMapStepJSON") private func BBMapStepJSON(
    _ task: UnsafePointer<CChar>, _ history: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("BBBridgeFreeJSON") private func BBMapFreeJSON(_ response: UnsafeMutablePointer<CChar>)
@_silgen_name("BBReleaseWakeLease") private func BBReleaseWakeLeaseForMap()

private final class MapResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = BeanBaoTextResult(succeeded: false, message: "Maps search incomplete. Check the screen.")
    func set(_ value: BeanBaoTextResult) { lock.lock(); result = value; lock.unlock() }
    func get() -> BeanBaoTextResult { lock.lock(); defer { lock.unlock() }; return result }
}

@_cdecl("BBRunHarnessMap")
public func BBRunHarnessMap(_ taskPointer: UnsafePointer<CChar>?) -> Int32 {
    runDeviceMap(taskPointer)
}

private func runDeviceMap(_ taskPointer: UnsafePointer<CChar>?) -> Int32 {
    guard let taskPointer else { return 2 }
    let task = String(cString: taskPointer)
    let step: BeanBaoMapStep = { command, history in
        let historyJSON = mapJSON(.array(history))
        return command.withCString { taskCString in
            historyJSON.withCString { historyCString in
                guard let reply = BBMapStepJSON(taskCString, historyCString) else {
                    return .object(["ok": .bool(false)])
                }
                defer { BBMapFreeJSON(reply) }
                return (try? JSONDecoder().decode(PHKJSONValue.self,
                           from: Data(String(cString: reply).utf8))) ?? .object(["ok": .bool(false)])
            }
        }
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = MapResultBox()
    Task.detached {
        box.set(await BeanBaoMapHarness.run(task, step: step))
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + .seconds(330)) == .success else {
        BBReleaseWakeLeaseForMap()
        fputs("Task exceeded its time or step limit\n", stderr)
        return 1
    }
    BBReleaseWakeLeaseForMap()
    let result = box.get()
    fputs(result.message + "\n", result.succeeded ? stdout : stderr)
    return result.succeeded ? 0 : 1
}
#endif
