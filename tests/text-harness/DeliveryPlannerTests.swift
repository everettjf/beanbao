import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private struct DeliveryScriptModel: PHKModelClient {
    let action: String
    let target: String
    let observationID: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let events: [PHKModelEvent]
        if request.messages.last?.role == .tool {
            events = [.contentDelta("One action proposed for review."), .completed(.stop)]
        } else {
            let arguments = "{\"action\":\"\(action)\",\"target\":\"\(target)\",\"observation_id\":\"\(observationID)\"}"
            events = [.toolCallDelta(.init(index: 0, id: "delivery-proposal", name: "delivery_choose",
                                           arguments: arguments)), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

final class DeliveryPlannerTests: XCTestCase {
    private func observation(_ url: String, _ text: String) -> BeanBaoUberEatsObservation {
        .init(url: URL(string: url)!, visibleText: text, bundleID: "dev.beanbao.app",
              observedAt: Date())
    }

    private func store() throws -> (BeanBaoWorkflowStore, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-delivery-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("session.json")
        return (try BeanBaoWorkflowStore(url: url, request: "Find a rice bowl"), url)
    }

    func testPalminoChoosesSeveralPageBoundActionsWithoutSavingPageText() async throws {
        let (journal, file) = try store()
        let pages: [(String, String, String, String)] = [
            ("https://www.ubereats.com/feed", "Search Uber Eats private-page-marker",
             "search", "rice bowl"),
            ("https://www.ubereats.com/search?q=rice", "Example Kitchen private-page-marker",
             "open_merchant", "Example Kitchen"),
            ("https://www.ubereats.com/store/example/id", "Search Uber Eats Rice bowl private-page-marker",
             "open_item", "Rice bowl"),
            ("https://www.ubereats.com/store/example/id?mod=quickView", "Rice bowl Add 1 to order private-page-marker",
             "add_to_cart", ""),
            ("https://www.ubereats.com/store/example/id", "Go to checkout private-page-marker",
             "open_checkout", "")
        ]
        for (url, text, action, target) in pages {
            let seen = observation(url, text)
            let id = try BeanBaoDeliveryObservationContract.identifier(seen)
            let proposal = try await BeanBaoDeliveryPlanner.choose(
                request: "Find a rice bowl", observation: seen, store: journal,
                client: DeliveryScriptModel(action: action, target: target, observationID: id),
                model: "scripted")
            XCTAssertEqual(proposal, .init(action: action, target: target, observationID: id))
            let saved = await journal.snapshot()
            XCTAssertEqual(saved.phase, .waitingForUser)
        }
        let data = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-page-marker"))
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.operations.count, pages.count)
        XCTAssertNil(saved.checkpoint)
        let last = pages.last!
        let lastPage = observation(last.0, last.1)
        let cached = try await BeanBaoDeliveryPlanner.choose(
            request: "Find a rice bowl", observation: lastPage, store: journal,
            client: DeliveryScriptModel(action: "place_order", target: "", observationID: "wrong"),
            model: "scripted")
        XCTAssertEqual(cached.action, "open_checkout")
        do {
            _ = try await BeanBaoDeliveryPlanner.choose(
                request: "Find a different meal", observation: lastPage, store: journal,
                client: DeliveryScriptModel(action: "place_order", target: "", observationID: "wrong"),
                model: "scripted")
            XCTFail("A different user request cannot reuse a saved proposal")
        } catch BeanBaoWorkflowError.invalidRecord { }
    }

    func testChangedPageAndOrderPlacementAreRejectedBeforeBrowserAction() async throws {
        let seen = observation("https://www.ubereats.com/store/example/id", "Go to checkout")
        let id = try BeanBaoDeliveryObservationContract.identifier(seen)
        let changed = observation("https://www.ubereats.com/store/example/id", "Go to checkout New total $27.99")
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "open_checkout", target: "", observationID: id),
            observation: changed))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "place_order", target: "", observationID: id),
            observation: seen))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "open_item", target: "Secret item", observationID: id),
            observation: seen))

        let (journal, _) = try store()
        do {
            _ = try await BeanBaoDeliveryPlanner.choose(
                request: "Find a rice bowl", observation: seen, store: journal,
                client: DeliveryScriptModel(action: "place_order", target: "", observationID: id),
                model: "scripted")
            XCTFail("The model cannot create a purchase action")
        } catch { }
        let saved = await journal.snapshot()
        XCTAssertTrue(saved.operations.isEmpty)
        XCTAssertEqual(saved.phase, .failed)
    }

    func testLoginAndStalePagesCannotBePlanned() throws {
        let login = observation("https://auth.uber.com/v2/", "Enter phone number")
        XCTAssertThrowsError(try BeanBaoDeliveryObservationContract.identifier(login))
        let old = BeanBaoUberEatsObservation(
            url: URL(string: "https://www.ubereats.com/feed")!, visibleText: "Search Uber Eats",
            bundleID: "dev.beanbao.app", observedAt: Date(timeIntervalSinceNow: -30))
        XCTAssertThrowsError(try BeanBaoDeliveryObservationContract.identifier(old))
    }
}
