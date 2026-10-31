import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private final class FakeNoteStepper: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedHistoryLengths: [Int] = []
    let failAt: Int?
    let doneAt: Int?

    init(failAt: Int? = nil, doneAt: Int? = nil) {
        self.failAt = failAt
        self.doneAt = doneAt
    }

    var calls: Int { lock.withLock { receivedHistoryLengths.count } }
    var historyLengths: [Int] { lock.withLock { receivedHistoryLengths } }

    func step(_ task: String, _ history: [PHKJSONValue]) -> PHKJSONValue {
        let count = lock.withLock { () -> Int in
            receivedHistoryLengths.append(history.count)
            return receivedHistoryLengths.count
        }
        if count == failAt { return .object(["ok": .bool(false), "error": .string("note_state")]) }
        if count == doneAt { return .object(["ok": .bool(true), "done": .bool(true)]) }
        return .object(["ok": .bool(true), "done": .bool(false),
                        "action": .object(["action": .string("tap"), "x": .number(Double(count))])])
    }
}

final class NoteHarnessTests: XCTestCase {
    func testLocalNoteStepsFinishOnlyAfterVerifiedDone() async {
        let fake = FakeNoteStepper(doneAt: 4)
        let result = await BeanBaoNoteHarness.run("新建备忘录：测试内容", step: fake.step)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(fake.historyLengths, [0, 1, 2, 3])
    }

    func testFailedStepCannotReportCreatedNote() async {
        let fake = FakeNoteStepper(failAt: 2)
        let result = await BeanBaoNoteHarness.run("新建备忘录：测试内容", step: fake.step)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.calls, 2)
    }

    func testUnsupportedNoteTaskNeverCallsDeviceStep() async {
        let fake = FakeNoteStepper(doneAt: 1)
        let result = await BeanBaoNoteHarness.run("打开地图", step: fake.step)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.calls, 0)
    }

    func testNoteStepBudgetStopsUnboundedProgress() async {
        let fake = FakeNoteStepper()
        let result = await BeanBaoNoteHarness.run("新建备忘录：测试内容", step: fake.step)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThanOrEqual(fake.calls, 10)
    }
}
