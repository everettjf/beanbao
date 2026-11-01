import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public typealias BeanBaoNoteStep = BeanBaoDeviceStep

private func noteJSON(_ value: PHKJSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

public enum BeanBaoNoteHarness {
    public static func run(_ task: String, step: @escaping BeanBaoNoteStep) async -> BeanBaoTextResult {
        guard task.hasPrefix("新建备忘录："), task.utf16.count >= 10, task.utf16.count <= 166,
              task.rangeOfCharacter(from: .newlines) == nil else {
            return .init(succeeded: false, message: "Invalid note request")
        }
        return await BeanBaoStepHarness.run(
            task, toolName: "note_step", maximumToolCalls: 10,
            maximumDuration: .seconds(300), successMessage: "Note created",
            failureMessage: "Notes screen is not safe to use", step: step)
    }
}

#if os(iOS)
@_silgen_name("BBNoteStepJSON") private func BBNoteStepJSON(
    _ task: UnsafePointer<CChar>, _ history: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("BBBridgeFreeJSON") private func BBNoteFreeJSON(_ response: UnsafeMutablePointer<CChar>)
@_silgen_name("BBReleaseWakeLease") private func BBReleaseWakeLease()

private final class NoteResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = BeanBaoTextResult(succeeded: false, message: "Notes screen is not safe to use")
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
        fputs("Notes screen is not safe to use\n", stderr)
        return 1
    }
    BBReleaseWakeLease()
    let result = box.get()
    fputs(result.message + "\n", result.succeeded ? stdout : stderr)
    return result.succeeded ? 0 : 1
}
#endif
