import Foundation
import XCTest
import AgentRuntime
@testable import BeanBaoTextHarness

private struct CustomOpenModel: PHKModelClient {
    let arguments: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let events: [PHKModelEvent] = request.messages.last?.role == .tool
            ? [.completed(.stop)]
            : [.toolCallDelta(.init(index: 0, id: UUID().uuidString,
                                    name: "open_app", arguments: arguments)),
               .completed(.toolCalls)]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private final class FakeBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground: String
    private var observationID = 0
    private var leaseActive = false
    private var actionCount = 0
    let locked: Bool
    let rejectAction: Bool
    let ignoreLaunch: Bool
    let timestampOffset: TimeInterval
    let switchAfterFirstObservation: String?

    init(locked: Bool = false, rejectAction: Bool = false, ignoreLaunch: Bool = false,
         timestampOffset: TimeInterval = 0, initialForeground: String = "com.apple.springboard",
         switchAfterFirstObservation: String? = nil) {
        self.locked = locked
        self.rejectAction = rejectAction
        self.ignoreLaunch = ignoreLaunch
        self.timestampOffset = timestampOffset
        self.foreground = initialForeground
        self.switchAfterFirstObservation = switchAfterFirstObservation
    }

    var actions: Int { lock.lock(); defer { lock.unlock() }; return actionCount }
    var leaseReleased: Bool { lock.lock(); defer { lock.unlock() }; return !leaseActive }

    func request(_ value: PHKJSONValue) -> PHKJSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard case .object(let fields) = value,
              case .string(let op)? = fields["op"] else { return .object(["ok": .bool(false)]) }
        switch op {
        case "wake_lease":
            guard case .string(let mode)? = fields["mode"] else { return .object(["ok": .bool(false)]) }
            if mode == "renew" {
                if locked { return .object(["ok": .bool(false)]) }
                leaseActive = true
            } else { leaseActive = false }
            return .object(["ok": .bool(true)])
        case "observe":
            observationID += 1
            let observedForeground = foreground
            if observationID == 1, let switchAfterFirstObservation {
                foreground = switchAfterFirstObservation
            }
            return .object([
                "ok": .bool(true), "observation_id": .string(String(observationID)),
                "timestamp": .number(Date().timeIntervalSince1970 + timestampOffset),
                "device_state": .object([
                    "locked_known": .bool(true), "locked": .bool(locked),
                    "screen_on_known": .bool(true), "screen_on": .bool(!locked)
                ]),
                "frontmost_app": .object(["bundleId": .string(observedForeground)])
            ])
        case "act":
            actionCount += 1
            guard !locked, !rejectAction,
                  case .string(let id)? = fields["observation_id"], id == String(observationID),
                  case .string("launch_app")? = fields["action"],
                  case .string(let bundle)? = fields["bundle_id"] else {
                return .object(["ok": .bool(false)])
            }
            if !ignoreLaunch { foreground = bundle }
            return .object(["ok": .bool(true)])
        default:
            return .object(["ok": .bool(false)])
        }
    }
}

final class TextHarnessTests: XCTestCase {
    func testFourAllowlistedTextCommandsReachVerifiedForeground() async {
        for task in BeanBaoTextHarness.targets.keys.sorted() {
            let fake = FakeBridge()
            let result = await BeanBaoTextHarness.run(task, bridge: fake.request)
            XCTAssertTrue(result.succeeded, task)
            XCTAssertEqual(fake.actions, 1, task)
            XCTAssertTrue(fake.leaseReleased, task)
        }
    }

    func testAlreadyForegroundNeedsTwoMatchingObservations() async {
        let stable = FakeBridge(initialForeground: "com.apple.Maps")
        let result = await BeanBaoTextHarness.run("打开地图", bridge: stable.request)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(stable.actions, 0)
        XCTAssertTrue(stable.leaseReleased)

        let switched = FakeBridge(initialForeground: "com.apple.Maps",
                                  switchAfterFirstObservation: "com.apple.springboard")
        let staleResult = await BeanBaoTextHarness.run("打开地图", bridge: switched.request)
        XCTAssertFalse(staleResult.succeeded)
        XCTAssertEqual(switched.actions, 0)
        XCTAssertTrue(switched.leaseReleased)
    }

    func testUnsupportedTaskDoesNotTouchBridge() async {
        let fake = FakeBridge()
        let result = await BeanBaoTextHarness.run("打开日历", bridge: fake.request)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.actions, 0)
    }

    func testLockedScreenDoesNotLaunchApp() async {
        let fake = FakeBridge(locked: true)
        let result = await BeanBaoTextHarness.run("打开地图", bridge: fake.request)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.actions, 0)
    }

    func testFutureObservationCannotLaunchApp() async {
        let fake = FakeBridge(timestampOffset: 60)
        let result = await BeanBaoTextHarness.run("打开地图", bridge: fake.request)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.actions, 0)
        XCTAssertTrue(fake.leaseReleased)
    }

    func testBridgeRejectionCannotBeReportedAsSuccess() async {
        let fake = FakeBridge(rejectAction: true)
        let result = await BeanBaoTextHarness.run("打开地图", bridge: fake.request)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.actions, 1)
        XCTAssertTrue(fake.leaseReleased)
    }

    func testUnverifiedLaunchCannotBeReportedAsSuccess() async {
        let fake = FakeBridge(ignoreLaunch: true)
        let result = await BeanBaoTextHarness.run("打开地图", bridge: fake.request)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(fake.actions, 1)
        XCTAssertTrue(fake.leaseReleased)
    }

    func testToolRegistryAndBeanBaoAllowlistRejectWrongBundleAndExtraArguments() async {
        for arguments in [
            "{\"bundle_id\":\"com.apple.Maps\"}",
            "{\"bundle_id\":\"com.apple.Preferences\",\"extra\":true}"
        ] {
            let fake = FakeBridge()
            let result = await BeanBaoTextHarness.run("打开设置", bridge: fake.request,
                                                     client: CustomOpenModel(arguments: arguments))
            XCTAssertFalse(result.succeeded, arguments)
            XCTAssertEqual(fake.actions, 0, arguments)
        }
    }
}
