import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private final class FakeMapStepper: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedHistoryLengths: [Int] = []
    let failAt: Int?
    let failureCode: String
    let doneAt: Int?

    init(failAt: Int? = nil, failureCode: String = "policy", doneAt: Int? = nil) {
        self.failAt = failAt
        self.failureCode = failureCode
        self.doneAt = doneAt
    }

    var calls: Int { lock.withLock { receivedHistoryLengths.count } }
    var historyLengths: [Int] { lock.withLock { receivedHistoryLengths } }

    func step(_ task: String, _ history: [PHKJSONValue]) -> PHKJSONValue {
        let count = lock.withLock { () -> Int in
            receivedHistoryLengths.append(history.count)
            return receivedHistoryLengths.count
        }
        if count == failAt { return .object(["ok": .bool(false), "error": .string(failureCode)]) }
        if count == doneAt { return .object(["ok": .bool(true), "done": .bool(true)]) }
        return .object(["ok": .bool(true), "done": .bool(false),
                        "action": .object(["action": .string("tap"), "x": .number(Double(count))])])
    }
}

final class MapHarnessTests: XCTestCase {
    func testMapSearchRequiresVerifiedDoneStep() async {
        let fake = FakeMapStepper(doneAt: 4)
        let result = await BeanBaoMapHarness.run("在地图搜索金门大桥", step: fake.step)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(fake.historyLengths, [0, 1, 2, 3])
    }

    func testMapFailureStopsWithoutFalseCompletion() async {
        let fake = FakeMapStepper(failAt: 2, failureCode: "policy")
        let result = await BeanBaoMapHarness.run("在地图搜索金门大桥", step: fake.step)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.message, "模型动作被策略拒绝")
        XCTAssertEqual(fake.calls, 2)
    }

    func testMapKeyFailureHasFixedMessage() async {
        let fake = FakeMapStepper(failAt: 1, failureCode: "key")
        let result = await BeanBaoMapHarness.run("在地图搜索金门大桥", step: fake.step)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.message, "Claude Key 未配置或权限不安全")
    }

    func testUnsupportedMapTaskNeverCallsDeviceStep() async {
        let fake = FakeMapStepper(doneAt: 1)
        let result = await BeanBaoMapHarness.run("打开地图", step: fake.step)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.calls, 0)
    }

    func testMapBudgetStopsUnboundedActions() async {
        let fake = FakeMapStepper()
        let result = await BeanBaoMapHarness.run("在地图搜索金门大桥", step: fake.step)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThanOrEqual(fake.calls, 20)
    }
}
