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
            return .init(succeeded: false, message: "无效的地图搜索指令")
        }
        return await BeanBaoStepHarness.run(
            task, toolName: "map_step", maximumToolCalls: 20,
            maximumDuration: .seconds(300), successMessage: "地图搜索已完成",
            failureMessage: "地图搜索未完成，请检查界面",
            failureMessages: [
                "key": "Claude Key 未配置或权限不安全",
                "locked": "设备已锁定或屏幕关闭",
                "wake_lease": "防自动锁屏不可用",
                "sensitive": "界面或任务疑似包含敏感信息",
                "model": "模型请求或输出失败",
                "policy": "模型动作被策略拒绝",
                "fresh_state": "界面复核未通过"
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
    private var result = BeanBaoTextResult(succeeded: false, message: "地图搜索未完成，请检查界面")
    func set(_ value: BeanBaoTextResult) { lock.lock(); result = value; lock.unlock() }
    func get() -> BeanBaoTextResult { lock.lock(); defer { lock.unlock() }; return result }
}

@_cdecl("BBRunHarnessMap")
public func BBRunHarnessMap(_ taskPointer: UnsafePointer<CChar>?) -> Int32 {
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
        fputs("任务超过时间或步数上限\n", stderr)
        return 1
    }
    BBReleaseWakeLeaseForMap()
    let result = box.get()
    fputs(result.message + "\n", result.succeeded ? stdout : stderr)
    return result.succeeded ? 0 : 1
}
#endif
